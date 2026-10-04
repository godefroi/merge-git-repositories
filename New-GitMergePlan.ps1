[CmdletBinding()]
param(
    # Output of Group-GitRepos.ps1 -JsonPath
    [Parameter(Mandatory = $true)]
    [string]$GroupsPath,

    # Group Ids to leave undecided (Status = 'held', no target name).
    [string[]]$Hold = @(),

    # Group Ids whose clones go to separate targets by their own remote URL instead of one target per group.
    [string[]]$SplitByRemote = @(),

    # Normalized remote URL -> target name, so several URLs for one repo (mirrors, moves) share a target.
    # Only used for groups in -SplitByRemote.
    [hashtable]$UrlAliases = @{},

    [Parameter(Mandatory = $true)]
    [string]$PlanPath
)

. "$PSScriptRoot\GitMerge.Common.ps1"

# Longest leading directory shared by every path (segment by segment, case-insensitive), so a clone id
# keeps only what tells clones apart.
function Get-CommonDirectory([string[]]$dirs) {
    $split = @($dirs | ForEach-Object { , ($_ -split '[\\/]') })
    $shortest = ($split | ForEach-Object Count | Measure-Object -Minimum).Minimum
    $common = @()
    for ($i = 0; $i -lt $shortest; $i++) {
        $segment = $split[0][$i]
        if ($split | Where-Object { $_[$i] -ne $segment }) { break }
        $common += $segment
    }
    $common -join '\'
}

# Ref-safe, readable id for a clone: its path below $clonePrefix with runs of non-alphanumerics collapsed to '-'.
function Get-CloneId([string]$path) {
    $rest = if ($path.StartsWith($clonePrefix, [StringComparison]::OrdinalIgnoreCase)) { $path.Substring($clonePrefix.Length) } else { $path }
    ($rest -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
}

function New-Clone($repo) {
    [PSCustomObject]@{
        Id       = Get-CloneId $repo.Path
        Path     = $repo.Path
        Remotes  = @($repo.Remotes | ForEach-Object { "$($_.Name)=$($_.Url)" })
        RefCount = $repo.RefCount
        Stashes  = $repo.Stashes
    }
}

$groups = @(Get-Content $GroupsPath -Raw | ConvertFrom-Json)
$clonePrefix = Get-CommonDirectory @($groups.Repos.Path | ForEach-Object { Split-Path $_ -Parent })
$targets = [System.Collections.Generic.List[object]]::new()

foreach ($g in $groups) {
    $status = if ($g.Id -in $Hold) { 'held' } else { 'ready' }

    # Each entry: the clones for one target plus how it's named and why.
    $buckets = if ($g.Id -in $SplitByRemote) {
        # A clone belongs to its origin's URL; extra remotes (e.g. a clone that also fetched another repo) don't move it.
        $g.Repos | Group-Object {
            $own = @($_.Remotes | Where-Object Name -eq 'origin') + @($_.Remotes) | Select-Object -First 1
            $url = Get-NormalizedUrl $own.Url
            if ($UrlAliases.ContainsKey($url)) { $UrlAliases[$url] } else { $url }
        } | ForEach-Object { [PSCustomObject]@{ Url = $_.Name; Repos = @($_.Group); Split = $true } }
    } else {
        [PSCustomObject]@{ Url = ($g.RemoteUrls | Select-Object -First 1); Repos = @($g.Repos); Split = $false }
    }

    foreach ($b in $buckets) {
        $name = if ($status -eq 'held') { $null }
                # Last segment of the URL; split on both separators because a remote can be a local Windows path.
                elseif ($b.Url) { ($b.Url -split '[\\/]')[-1] -replace '[:*?"<>|]', '-' }
                else { (Split-Path $b.Repos[0].Path -Leaf).ToLowerInvariant() }
        $targets.Add([PSCustomObject]@{
            Name       = $name
            Status     = $status
            GroupId    = $g.Id
            SplitByRemote = $b.Split
            RemoteUrls = @($b.Repos.Remotes.Url | Where-Object { $_ } | ForEach-Object { Get-NormalizedUrl $_ } | Sort-Object -Unique)
            Clones     = @($b.Repos | ForEach-Object { New-Clone $_ })
        })
    }
}

# Names and clone ids must be unique, since they become directory names and ref namespaces.
$seen = @{}
foreach ($t in $targets | Where-Object Name) {
    $base = $t.Name; $n = 2
    while ($seen.ContainsKey($t.Name)) { $t.Name = "$base-$n"; $n++ }
    $seen[$t.Name] = $true
    if ($t.Name -ne $base) { Write-Warning "Target name '$base' collides; using '$($t.Name)' (group $($t.GroupId))" }
}
$dupIds = $targets.Clones.Id | Group-Object | Where-Object Count -gt 1
if ($dupIds) { throw "Clone ids not unique: $($dupIds.Name -join ', ')" }

ConvertTo-Json -InputObject @($targets) -Depth 6 | Set-Content -Path $PlanPath -Encoding utf8
$targets
