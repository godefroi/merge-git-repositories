[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    # Wildcard patterns on target names; default is every target.
    [string[]]$Target
)

. "$PSScriptRoot\GitMerge.Common.ps1"

# One object per source clone that has untracked (not ignored) files, with every file's size and git blob hash.
# The hash is what lets two clones' copies of "the same" file be compared without reading them side by side.
$plan = @(Get-Content $PlanPath -Raw | ConvertFrom-Json)
foreach ($t in $plan) {
    if ($Target -and -not ($Target | Where-Object { $t.Name -like $_ })) { continue }
    foreach ($c in $t.Clones) {
        if (-not (Test-Path -LiteralPath $c.Path -PathType Container)) { continue }

        # quotepath=off keeps non-ASCII names readable instead of octal-escaped.
        $names = @(Invoke-Git $c.Path @('-c', 'core.quotepath=off', 'ls-files', '--others', '--exclude-standard'))
        if (-not $names) { continue }
        $files = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $names.Count; $i += 100) {
            $chunk = $names[$i..([Math]::Min($i + 99, $names.Count - 1))]
            $hashes = @(Invoke-Git $c.Path (@('hash-object', '--') + $chunk))
            for ($j = 0; $j -lt $chunk.Count; $j++) {
                $item = Get-Item -LiteralPath (Join-Path $c.Path $chunk[$j]) -ErrorAction SilentlyContinue
                $files.Add([PSCustomObject]@{ Path = $chunk[$j]; Size = $item.Length; Hash = $hashes[$j] })
            }
        }
        [PSCustomObject]@{
            Target     = $t.Name
            Clone      = $c.Id
            SourcePath = $c.Path
            FileCount  = $files.Count
            TotalBytes = ($files | Measure-Object Size -Sum).Sum
            Files      = @($files)
        }
    }
}
