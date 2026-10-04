[CmdletBinding(SupportsShouldProcess)]
param(
    # Output of New-GitMergePlan.ps1
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$OutputRoot = '.\_merged_repos',

    # Wildcard patterns on target names; default is every ready target.
    [string[]]$Target,

    # Delete and rebuild a target that already exists in $OutputRoot (otherwise it is skipped).
    [switch]$Rebuild,

    # Also write the per-target results (including every diverged ref) to this file as JSON.
    [string]$ReportPath
)

. "$PSScriptRoot\GitMerge.Common.ps1"

$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)

# Sources are only ever read: fetch and upload-pack don't write to the repo they fetch from.
# Each clone is staged under refs/clones/<id>/*, then collapsed into refs/heads, refs/tags, ...:
#   - same ref in several clones: keep the tip that contains the others (the one with more commits)
#   - tips that don't contain each other (or tags that disagree): never guessed, all kept under refs/diverged/<id>/...
function Get-CanonicalRef([string]$rest) {
    if ($rest -match '^remotes/[^/]+/HEAD$') { return $null }                 # symbolic ref, adds nothing
    if ($rest -match '^heads/(.+)$') { return "refs/heads/$($Matches[1])" }
    # Only origin's tracking branches are branch candidates; another remote's `main` is a different repo's main.
    if ($rest -match '^remotes/origin/(.+)$') { return "refs/heads/$($Matches[1])" }
    "refs/$rest"
}

function Test-Ancestor([string]$dir, [string]$maybeAncestor, [string]$of) {
    $null = Invoke-Git $dir @('merge-base', '--is-ancestor', $maybeAncestor, $of)
    $script:GitExit -eq 0
}

# Moves a candidate to refs/diverged/<clone>/<its original name>; unique per clone because it mirrors the staging name.
function Add-Diverted($diverted, $cand) { $diverted["refs/diverged/$($cand.Clone)/$($cand.Rest)"] = $cand.Sha }

# Committer time of a commit (or the commit a tag peels to); 0 if it isn't one.
function Get-CommitTime([string]$dir, [string]$sha) {
    $t = @(Invoke-Git $dir @('log', '-1', '--format=%ct', $sha))
    if ($script:GitExit -eq 0 -and $t) { [long]$t[0] } else { 0 }
}

# The shas not contained by any other sha in the set.
function Get-MaximalShas([string]$dir, [string[]]$shas) {
    foreach ($s in $shas) {
        $dominated = $false
        foreach ($o in $shas) {
            if ($o -eq $s -or -not (Test-Ancestor $dir $s $o)) { continue }
            # Two different tag objects on the same commit contain each other; keep one (the smaller sha loses) so exactly one survives.
            if (Test-Ancestor $dir $o $s) { if ([string]::CompareOrdinal($o, $s) -lt 0) { $dominated = $true; break } }
            else { $dominated = $true; break }
        }
        if (-not $dominated) { $s }
    }
}

$plan = @(Get-Content $PlanPath -Raw | ConvertFrom-Json)
$selected = foreach ($t in $plan) {
    if ($t.Status -ne 'ready') { continue }
    if (-not $Target -or ($Target | Where-Object { $t.Name -like $_ })) { $t }
}
if (-not $selected) { throw 'No ready targets match.' }

$results = foreach ($t in $selected) {
    $dir = Join-Path $OutputRoot "$($t.Name).git"
    $r = [PSCustomObject]@{ Name = $t.Name; Status = 'built'; Clones = $t.Clones.Count; Refs = 0; Superseded = 0; Diverged = @(); Errors = @() }

    try {
        if (Test-Path -LiteralPath $dir) {
            if (-not $Rebuild) { $r.Status = 'skipped (exists)'; $r; continue }
            if ($PSCmdlet.ShouldProcess($dir, 'delete existing target')) { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
        if (-not $PSCmdlet.ShouldProcess($dir, "build from $($t.Clones.Count) clone(s)")) { $r.Status = 'whatif'; $r; continue }

        $null = New-Item -ItemType Directory -Path $dir
        $null = Invoke-Git $dir @('init', '--bare', '--quiet')

        foreach ($c in $t.Clones) {
            $out = Invoke-Git $dir @('fetch', '--quiet', '--no-tags', '--no-write-fetch-head', $c.Path, "+refs/*:refs/clones/$($c.Id)/*") -MergeStderr
            if ($script:GitExit -ne 0) { throw "fetch of $($c.Path) failed: $($out -join ' ')" }
            # Separate fetch: a detached HEAD is outside refs/*, and an unborn HEAD would fail the whole fetch above.
            $null = Invoke-Git $dir @('fetch', '--quiet', '--no-tags', '--no-write-fetch-head', $c.Path, "+HEAD:refs/clones/$($c.Id)/HEAD")
        }

        # Collect every staged ref as a candidate for its canonical name.
        $headOf = @{}
        $cands = @{}
        foreach ($line in @(Invoke-Git $dir @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/clones'))) {
            $name, $sha = $line -split ' '
            if ($name -notmatch '^refs/clones/([^/]+)/(.+)$') { continue }
            $x = [PSCustomObject]@{ Clone = $Matches[1]; Rest = $Matches[2]; Sha = $sha }
            if ($x.Rest -eq 'HEAD') { $headOf[$x.Clone] = $sha; continue }
            $canon = Get-CanonicalRef $x.Rest
            if (-not $canon) { continue }
            if (-not $cands.ContainsKey($canon)) { $cands[$canon] = [System.Collections.Generic.List[object]]::new() }
            $cands[$canon].Add($x)
        }

        $keep = @{}        # canonical ref -> sha
        $diverted = @{}    # refs/diverged/... -> sha
        $report = [System.Collections.Generic.List[object]]::new()

        foreach ($canon in $cands.Keys | Sort-Object) {
            $list = $cands[$canon]
            $shas = @($list.Sha | Sort-Object -Unique)
            # @(): without it a one-element result unrolls to a string and $maximal[0] is its first character.
            $maximal = @(if ($shas.Count -eq 1) { $shas } else { Get-MaximalShas $dir $shas })
            $r.Superseded += $shas.Count - $maximal.Count
            if ($maximal.Count -eq 1) { $keep[$canon] = $maximal[0]; continue }

            # Tips that don't contain each other: the most recent commit keeps the plain name, the rest go to refs/diverged.
            $newest = $maximal | Sort-Object { Get-CommitTime $dir $_ }, { $_ } -Descending | Select-Object -First 1
            $keep[$canon] = $newest
            foreach ($m in $maximal | Where-Object { $_ -ne $newest }) { Add-Diverted $diverted ($list | Where-Object Sha -eq $m | Select-Object -First 1) }
            $report.Add([PSCustomObject]@{
                Ref = $canon; Kind = 'diverged'
                Candidates = @($list | ForEach-Object { "$($_.Clone):$($_.Rest)@$($_.Sha.Substring(0, 8))" } | Sort-Object -Unique)
                Canonical = $newest.Substring(0, 8)
                Kept = @($maximal | ForEach-Object { $_.Substring(0, 8) })
            })
        }

        # git can't hold refs/heads/foo and refs/heads/foo/bar at once (one clone had the branch, another a sub-branch).
        $prefixes = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($k in $keep.Keys) {
            $parts = $k -split '/'
            for ($i = 1; $i -lt $parts.Count; $i++) { [void]$prefixes.Add(($parts[0..($i - 1)] -join '/')) }
        }
        foreach ($k in @($keep.Keys | Where-Object { $prefixes.Contains($_) })) {
            Add-Diverted $diverted ($cands[$k] | Where-Object Sha -eq $keep[$k] | Select-Object -First 1)
            $report.Add([PSCustomObject]@{ Ref = $k; Kind = 'name-conflict'; Candidates = @($k); Kept = @($keep[$k].Substring(0, 8)) })
            $keep.Remove($k)
        }

        foreach ($set in $keep, $diverted) {
            foreach ($k in $set.Keys | Sort-Object) {
                $out = Invoke-Git $dir @('update-ref', $k, $set[$k]) -MergeStderr
                if ($script:GitExit -ne 0) { $r.Errors += "update-ref $k $($set[$k]) failed: $($out -join ' ')" }
            }
        }

        # A detached HEAD whose commit no kept ref contains would be lost with its source.
        $keptShas = Get-KeptShas $dir
        foreach ($clone in $headOf.Keys | Sort-Object) {
            if ((Test-Covered $dir $headOf[$clone] $keptShas) -eq 'none') {
                $null = Invoke-Git $dir @('update-ref', "refs/diverged/$clone/HEAD", $headOf[$clone])
                [void]$keptShas.Add($headOf[$clone])
                $report.Add([PSCustomObject]@{ Ref = "HEAD of $clone"; Kind = 'detached-head'; Candidates = @($clone); Kept = @($headOf[$clone].Substring(0, 8)) })
            }
        }

        # Point HEAD at a branch that exists so a clone of the target checks something out.
        $branch = @('refs/heads/main', 'refs/heads/master') + @($keep.Keys | Where-Object { $_ -like 'refs/heads/*' } | Sort-Object) |
            Where-Object { $keep.ContainsKey($_) } | Select-Object -First 1
        if ($branch) { $null = Invoke-Git $dir @('symbolic-ref', 'HEAD', $branch) }

        $r.Refs = $keep.Count
        $r.Diverged = @($report)
    }
    catch {
        $r.Status = 'failed'
        $r.Errors += $_.Exception.Message
    }
    if ($r.Errors.Count -and $r.Status -eq 'built') { $r.Status = 'built with errors' }
    $r
}

if ($ReportPath) { ConvertTo-Json -InputObject @($results) -Depth 6 | Set-Content -Path $ReportPath -Encoding utf8 }
$results
