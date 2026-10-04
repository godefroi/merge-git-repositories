[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$OutputRoot = '.\_merged_repos',

    # Wildcard patterns on target names; default is every ready target.
    [string[]]$Target
)

. "$PSScriptRoot\GitMerge.Common.ps1"

$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)

# One row per source clone. Pass means every tip in that clone (all refs plus a detached HEAD) is a kept ref
# or an ancestor of one in the built target, the target's object graph is intact, and any uncommitted work in the clone
# is captured under refs/wip. Never writes to the sources (it can add unreachable loose objects to a target).
$plan = @(Get-Content $PlanPath -Raw | ConvertFrom-Json)
foreach ($t in $plan) {
    if ($t.Status -ne 'ready') { continue }
    if ($Target -and -not ($Target | Where-Object { $t.Name -like $_ })) { continue }

    $dir = Join-Path $OutputRoot "$($t.Name).git"
    $built = Test-Path -LiteralPath $dir
    $fsckOk = $false
    $kept = $null
    if ($built) {
        $null = Invoke-Git $dir @('fsck', '--connectivity-only', '--no-dangling', '--no-progress') -MergeStderr
        $fsckOk = $script:GitExit -eq 0
        $kept = Get-KeptShas $dir
    }
    $cache = @{}

    # Every uncommitted-change key (path|mode|blob) carried by any refs/wip commit in this target.
    $wipKeys = [System.Collections.Generic.HashSet[string]]::new()
    if ($built) {
        foreach ($ref in @(Invoke-Git $dir @('for-each-ref', '--format=%(refname)', 'refs/wip'))) {
            $base = @(Invoke-Git $dir @('rev-parse', "$ref^"))[0]
            $wipTree = @(Invoke-Git $dir @('rev-parse', ($ref + '^{tree}')))[0]
            foreach ($k in @(Get-WipKeys $dir $base $wipTree)) { [void]$wipKeys.Add($k) }
        }
    }

    foreach ($c in $t.Clones) {
        $row = [PSCustomObject]@{ Target = $t.Name; Clone = $c.Id; Path = $c.Path; Tips = 0; Exact = 0; Ancestor = 0; TagObjectOnly = 0; Uncovered = 0
                                  Wip = 'none'; FsckOk = $fsckOk; Pass = $false; Problem = $null; UncoveredRefs = @(); TagObjectRefs = @() }
        if (-not $built) { $row.Problem = 'target not built'; $row; continue }
        if (-not (Test-Path -LiteralPath $c.Path -PathType Container)) { $row.Problem = 'source missing'; $row; continue }

        $tips = @{}   # sha -> a ref name that points at it (for the report)
        foreach ($line in @(Invoke-Git $c.Path @('for-each-ref', '--format=%(refname) %(objectname)'))) {
            $name, $sha = $line -split ' '
            if (-not $tips.ContainsKey($sha)) { $tips[$sha] = $name }
        }
        $head = @(Invoke-Git $c.Path @('rev-parse', '--verify', '-q', 'HEAD'))
        if ($script:GitExit -eq 0 -and $head -and -not $tips.ContainsKey($head[0])) { $tips[$head[0]] = 'HEAD' }

        foreach ($sha in $tips.Keys) {
            if (-not $cache.ContainsKey($sha)) { $cache[$sha] = Test-Covered $dir $sha $kept }
            $cov = $cache[$sha]
            if ($cov -eq 'none') {
                # A superseded annotated tag: its tag object (tagger, date, message) is gone once nothing references it,
                # but the commit it pointed at is still covered. Reported separately so it is a visible, accepted loss.
                $peeled = @(Invoke-Git $c.Path @('rev-parse', '--verify', '-q', ($sha + '^{commit}')))
                if ($script:GitExit -eq 0 -and $peeled -and $peeled[0] -ne $sha -and (Test-Covered $dir $peeled[0] $kept) -ne 'none') { $cov = 'tag-object-only' }
            }
            switch ($cov) {
                'exact'           { $row.Exact++ }
                'ancestor'        { $row.Ancestor++ }
                'tag-object-only' { $row.TagObjectOnly++; $row.TagObjectRefs += "$($tips[$sha]) $sha" }
                default           { $row.Uncovered++; $row.UncoveredRefs += "$($tips[$sha]) $sha" }
            }
        }
        $row.Tips = $tips.Count

        # Uncommitted work: recompute the clone's working tree now and require that its changes are in the target,
        # either as this clone's own refs/wip commit (same tree) or entirely within another clone's wip commits.
        if (@(Invoke-Git $c.Path @('status', '--porcelain'))) {
            $headSha = @(Invoke-Git $c.Path @('rev-parse', 'HEAD'))[0]
            $tree = Get-WorktreeTree $c.Path $dir   # adds loose objects to the target; unreachable ones are pruned at finalize
            $keys = @(Get-WipKeys $dir $headSha $tree)
            $ownWip = @(Invoke-Git $dir @('rev-parse', '--verify', '-q', "refs/wip/$($c.Id)^{tree}"))
            $row.Wip = if (-not $keys) { 'none' }
                       elseif ($ownWip) { if ($ownWip[0] -eq $tree) { 'captured' } else { 'STALE' } }
                       elseif (-not @($keys | Where-Object { -not $wipKeys.Contains($_) })) { 'duplicate' }
                       else { 'MISSING' }
        }

        if (-not $fsckOk) { $row.Problem = 'fsck reported errors in target' }
        elseif ($row.Tips -eq 0) { $row.Problem = 'source has no refs' }
        elseif ($row.Wip -in 'STALE', 'MISSING') { $row.Problem = "uncommitted changes not captured ($($row.Wip))" }
        $row.Pass = $fsckOk -and $row.Uncovered -eq 0 -and $row.Tips -gt 0 -and $row.Wip -notin 'STALE', 'MISSING'
        $row
    }
}
