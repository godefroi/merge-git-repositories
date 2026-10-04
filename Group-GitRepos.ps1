[CmdletBinding()]
param(
    # Output of Get-GitRepoStatus.ps1 -JsonPath
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,

    # When set, the groups are also written to this file as JSON.
    [string]$JsonPath
)

. "$PSScriptRoot\GitMerge.Common.ps1"

# Repos are in the same group if they share any root commit (connected components).
# Single-root grouping isn't enough: many repos have several roots from merged-in histories.

$all = @(Get-Content $StatusPath -Raw | ConvertFrom-Json)

$skipped = [System.Collections.Generic.List[object]]::new()
$repos = [System.Collections.Generic.List[object]]::new()
foreach ($r in $all) {
    $reason = if (-not (Test-Path $r.Path -PathType Container)) { 'path no longer exists' }
              elseif (-not $r.IsGitRepository) { 'not a git repository' }
              elseif ($r.RootCommits.Count -eq 0) { 'no commits' }
              elseif ($r.IsShallow) { 'shallow (roots unreliable)' }
    if ($reason) { $skipped.Add([PSCustomObject]@{ Path = $r.Path; Reason = $reason }) } else { $repos.Add($r) }
}

# Union-find over repo indexes; $firstOwner remembers which repo first claimed each root.
$parent = 0..($repos.Count - 1)
function Find($i) { while ($parent[$i] -ne $i) { $parent[$i] = $parent[$parent[$i]]; $i = $parent[$i] }; $i }
$firstOwner = @{}
for ($i = 0; $i -lt $repos.Count; $i++) {
    foreach ($root in $repos[$i].RootCommits) {
        if ($firstOwner.ContainsKey($root)) { $parent[(Find $i)] = Find $firstOwner[$root] } else { $firstOwner[$root] = $i }
    }
}

$groups = @(for ($i = 0; $i -lt $repos.Count; $i++) { [PSCustomObject]@{ Key = Find $i; Repo = $repos[$i] } }) |
    Group-Object Key | ForEach-Object {
        $members = @($_.Group.Repo)
        $roots = @($members.RootCommits | Sort-Object -Unique)
        $urls = @($members.Remotes.Url | Where-Object { $_ } | ForEach-Object { Get-NormalizedUrl $_ } | Sort-Object -Unique)
        [PSCustomObject]@{
            Id             = $roots[0].Substring(0, 12)   # first (sorted) root; stable as long as the clone set's roots are
            Roots          = $roots
            RemoteUrls     = $urls
            RepoCount      = $members.Count
            # Multi-root members are the only ones that can have joined otherwise-unrelated histories.
            MultiRootRepos = @($members | Where-Object { $_.RootCommits.Count -gt 1 } | ForEach-Object Path)
            Repos          = @($members | ForEach-Object {
                [PSCustomObject]@{ Path = $_.Path; Head = $_.Head; RefCount = $_.RefCount; RootCount = $_.RootCommits.Count
                                   Remotes = $_.Remotes; Untracked = $_.UntrackedFiles; Stashes = $_.StashCount }
            })
        }
    } | Sort-Object RepoCount -Descending

# Validation: the same remote URL showing up in two groups means grouping missed a link (or a remote was reused).
$urlGroups = @{}
for ($g = 0; $g -lt @($groups).Count; $g++) { foreach ($u in $groups[$g].RemoteUrls) { $urlGroups[$u] += @($g) } }
foreach ($s in $skipped) { Write-Warning "Skipped ($($s.Reason)): $($s.Path)" }
foreach ($e in $urlGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }) {
    Write-Warning "Remote $($e.Key) appears in groups $($e.Value -join ', ')"
}

# -InputObject keeps a single group serialized as an array instead of unrolling to an object.
if ($JsonPath) { ConvertTo-Json -InputObject @($groups) -Depth 6 | Set-Content -Path $JsonPath -Encoding utf8 }
$groups
