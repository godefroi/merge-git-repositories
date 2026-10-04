[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [string]$OutputRoot = '.\_merged_repos',

    # Wildcard patterns on target names; default is every ready target.
    [string[]]$Target
)

. "$PSScriptRoot\GitMerge.Common.ps1"

$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)

# Removes each target's refs/clones/* staging area, then expires reflogs and prunes, so only the resolved refs
# (heads, tags, remotes, diverged, wip, ...) and what they reach stay. Run the verifier first and again afterwards.
# After this a target can no longer be extended with Capture-GitWip.ps1 (it needs the staged HEAD); rebuild it from the sources instead.

# `update-ref --stdin` needs LF line endings; PowerShell's native pipe sends CRLF, so write the bytes ourselves.
function Invoke-GitStdin([string]$Dir, [string[]]$GitArgs, [string]$Text) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in @('-C', $Dir) + $GitArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Text); $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEnd(); $null = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "git $($GitArgs -join ' ') failed: $err" }
}

# Total object storage in KiB (loose + packed), from git itself; walking thousands of loose files over a share-sized tree is slow.
function Get-ObjectKiB([string]$Dir) {
    $sum = 0
    foreach ($line in @(Invoke-Git $Dir @('count-objects', '-v'))) { if ($line -match '^(size|size-pack): (\d+)$') { $sum += [int]$Matches[2] } }
    $sum
}

$plan = @(Get-Content $PlanPath -Raw | ConvertFrom-Json)
foreach ($t in $plan) {
    if ($t.Status -ne 'ready') { continue }
    if ($Target -and -not ($Target | Where-Object { $t.Name -like $_ })) { continue }

    $dir = Join-Path $OutputRoot "$($t.Name).git"
    $r = [PSCustomObject]@{ Target = $t.Name; Status = 'finalized'; StagingRefsRemoved = 0; BeforeKiB = $null; AfterKiB = $null; Error = $null }
    try {
        if (-not (Test-Path -LiteralPath $dir)) { $r.Status = 'target not built'; $r; continue }
        $r.BeforeKiB = Get-ObjectKiB $dir
        $staging = @(Invoke-Git $dir @('for-each-ref', '--format=%(refname)', 'refs/clones'))
        if (-not $PSCmdlet.ShouldProcess($dir, "remove $($staging.Count) staging ref(s), expire reflogs and prune")) { $r.Status = 'whatif'; $r.StagingRefsRemoved = $staging.Count; $r; continue }

        if ($staging) { Invoke-GitStdin $dir @('update-ref', '--stdin') ((($staging | ForEach-Object { "delete $_" }) -join "`n") + "`n") }
        $r.StagingRefsRemoved = $staging.Count
        $null = Invoke-Git $dir @('reflog', 'expire', '--expire=now', '--all')
        $out = Invoke-Git $dir @('gc', '--prune=now', '--quiet') -MergeStderr
        if ($script:GitExit -ne 0) { throw "gc failed: $($out -join ' ')" }
        $r.AfterKiB = Get-ObjectKiB $dir
    }
    catch { $r.Status = 'failed'; $r.Error = $_.Exception.Message }
    $r
}
