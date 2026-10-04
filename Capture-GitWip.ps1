[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$OutputRoot = '.\_merged_repos',

    # Wildcard patterns on target names; default is every ready target.
    [string[]]$Target,

    # Delete a target's existing refs/wip/* and capture again (otherwise a target that has any is skipped).
    [switch]$Rebuild
)

. "$PSScriptRoot\GitMerge.Common.ps1"

$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)

# Captures each clone's uncommitted work (tracked changes plus non-ignored untracked files) as ONE commit on top of
# that clone's own HEAD, stored as refs/wip/<clone> in the target. Sources are only read.
# Within a target, a clone whose changes are all already captured by an earlier clone (same path, mode and content)
# is skipped, so duplicate backups of the same uncommitted work are kept once. A clone that is captured is captured in full,
# so each wip commit is a faithful picture of one clone.
$plan = @(Get-Content $PlanPath -Raw | ConvertFrom-Json)
foreach ($t in $plan) {
    if ($t.Status -ne 'ready') { continue }
    if ($Target -and -not ($Target | Where-Object { $t.Name -like $_ })) { continue }

    $dir = Join-Path $OutputRoot "$($t.Name).git"
    $row = { param($c, $action, $files = 0, $ref = $null, $dup = @(), $err = $null)
             [PSCustomObject]@{ Target = $t.Name; Clone = $c.Id; Path = $c.Path; Action = $action; Files = $files; WipRef = $ref; DuplicateOf = $dup; Error = $err } }
    if (-not (Test-Path -LiteralPath $dir)) { foreach ($c in $t.Clones) { & $row $c 'target not built' }; continue }

    $existing = @(Invoke-Git $dir @('for-each-ref', '--format=%(refname)', 'refs/wip'))
    if ($existing -and -not $Rebuild) { foreach ($c in $t.Clones) { & $row $c 'skipped (target already has refs/wip)' }; continue }
    if ($existing -and $PSCmdlet.ShouldProcess($dir, 'delete existing refs/wip/*')) {
        foreach ($ref in $existing) { $null = Invoke-Git $dir @('update-ref', '-d', $ref) }
    }

    $captured = @{}   # key -> clone id that carries it
    foreach ($c in $t.Clones) {
        try {
            if (-not (Test-Path -LiteralPath $c.Path -PathType Container)) { & $row $c 'source missing'; continue }

            # Cheap pre-filter on the source's own (cached) index, so clean clones aren't read in full.
            $status = @(Invoke-Git $c.Path @('status', '--porcelain'))
            if (-not $status) { continue }

            $head = @(Invoke-Git $c.Path @('rev-parse', 'HEAD'))[0]
            $staged = @(Invoke-Git $dir @('rev-parse', '--verify', '-q', "refs/clones/$($c.Id)/HEAD"))[0]
            if ($head -ne $staged) { throw "source HEAD $head differs from the commit built into the target ($staged); rebuild the target first" }

            $tree = Get-WorktreeTree $c.Path $dir
            $keys = @(Get-WipKeys $dir $head $tree)
            if (-not $keys) { & $row $c 'no content change'; continue }

            $newKeys = @($keys | Where-Object { -not $captured.ContainsKey($_) })
            if (-not $newKeys) {
                & $row $c 'skip-duplicate' $keys.Count $null @($keys | ForEach-Object { $captured[$_] } | Sort-Object -Unique)
                continue
            }

            $ref = "refs/wip/$($c.Id)"
            if ($PSCmdlet.ShouldProcess($dir, "capture $($keys.Count) changed file(s) from $($c.Path) as $ref")) {
                $index = Join-Path ([IO.Path]::GetTempPath()) "gitmerge-$([guid]::NewGuid()).idx"
                $commit = @(Invoke-GitWorktree $c.Path $dir $index @('commit-tree', $tree, '-p', $head, '-m', "Uncommitted changes captured from $($c.Path)"))
                if ($script:GitExit -ne 0 -or -not $commit) { throw 'commit-tree failed' }
                $null = Invoke-Git $dir @('update-ref', $ref, $commit[0])
                if ($script:GitExit -ne 0) { throw "update-ref $ref failed" }
            }
            foreach ($k in $keys) { if (-not $captured.ContainsKey($k)) { $captured[$k] = $c.Id } }
            & $row $c 'capture' $keys.Count $ref
        }
        catch { & $row $c 'failed' 0 $null @() $_.Exception.Message }
    }
}
