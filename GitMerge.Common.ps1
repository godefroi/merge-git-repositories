# Shared helpers, dot-sourced by the other scripts. Build and verify both use the definition of "covered" below.

# Makes the same repo recognizable across URL styles: lowercase, no scheme, no user@, scp-style host:path as host/path, no .git.
function Get-NormalizedUrl([string]$url) {
    $u = $url.ToLowerInvariant()
    $u = $u -replace '^[a-z+]+://', ''
    $u = $u -replace '^[^@/]+@', ''
    $u = $u -replace '^([^/:]+):(?!\d+/)', '$1/'
    $u -replace '(\.git)?/?$', ''
}

# Runs git against $Dir and returns output lines; the exit code lands in $script:GitExit.
# Callers wrap in @() because a single line comes back as a bare string and an empty result as $null.
# safe.directory='*': UNC shares fail git's ownership check otherwise.
# --no-optional-locks: reads of a source repo must never write to it (e.g. refresh its index).
function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs, [switch]$MergeStderr)
    $out = if ($MergeStderr) { @(git -c safe.directory='*' --no-optional-locks -C $Dir @GitArgs 2>&1) }
           else { @(git -c safe.directory='*' --no-optional-locks -C $Dir @GitArgs 2>$null) }
    $script:GitExit = $LASTEXITCODE
    $out
}

# Runs git as the source clone (its config, .gitignore/info/exclude, attributes and working tree) but with
# every object read from and written to $TargetDir's object store, and the index in a temp file, so the source is never written to.
# No alternates pointing at the source: git would then "freshen" (touch the mtime of) source objects that already exist.
# The target already has the clone's HEAD commit and trees, which is all read-tree needs.
function Invoke-GitWorktree {
    param([string]$Source, [string]$TargetDir, [string]$Index, [string[]]$GitArgs, [switch]$MergeStderr)
    $vars = @{
        GIT_DIR = Join-Path $Source '.git'; GIT_WORK_TREE = $Source; GIT_INDEX_FILE = $Index
        GIT_OBJECT_DIRECTORY = Join-Path $TargetDir 'objects'
        GIT_AUTHOR_NAME = 'gitmerge'; GIT_AUTHOR_EMAIL = 'gitmerge@localhost'
        GIT_COMMITTER_NAME = 'gitmerge'; GIT_COMMITTER_EMAIL = 'gitmerge@localhost'
    }
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try { Invoke-Git $Source $GitArgs -MergeStderr:$MergeStderr }
    finally {
        # Setting a variable back to $null leaves it defined as an empty string (git then fails with "not a git repository: ''"),
        # so unset it. -WhatIf:$false: a caller's -WhatIf must not stop this cleanup.
        foreach ($k in $saved.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue -WhatIf:$false }
            else { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }
}

# Tree object (written into $TargetDir) of a clone's working state: its HEAD plus every tracked change and every
# non-ignored untracked file. `add -A` in a throwaway index applies the source's own ignore rules.
function Get-WorktreeTree([string]$Source, [string]$TargetDir) {
    $index = Join-Path ([IO.Path]::GetTempPath()) "gitmerge-$([guid]::NewGuid()).idx"
    try {
        $out = Invoke-GitWorktree $Source $TargetDir $index @('read-tree', 'HEAD') -MergeStderr
        if ($script:GitExit -ne 0) { throw "read-tree failed in ${Source}: $($out -join ' ')" }
        $out = Invoke-GitWorktree $Source $TargetDir $index @('add', '-A') -MergeStderr
        if ($script:GitExit -ne 0) { throw "add -A failed in ${Source}: $($out -join ' ')" }
        $tree = @(Invoke-GitWorktree $Source $TargetDir $index @('write-tree'))
        if ($script:GitExit -ne 0 -or -not $tree) { throw "write-tree failed in $Source" }
        $tree[0]
    }
    finally { Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}

# What a working-tree tree changes relative to its base commit, one "path|mode|blob" key per changed path
# (a deletion has mode 000000). Two clones with the same keys have the same uncommitted content.
function Get-WipKeys([string]$TargetDir, [string]$BaseCommit, [string]$Tree) {
    foreach ($line in @(Invoke-Git $TargetDir @('-c', 'core.quotepath=off', 'diff-tree', '-r', '--no-renames', $BaseCommit, $Tree))) {
        if ($line -match '^:\d+ (\d+) [0-9a-f]+ ([0-9a-f]+) \w\t(.+)$') { "$($Matches[3])|$($Matches[1])|$($Matches[2])" }
    }
}

# Every object a ref in $Dir points at, ignoring the refs/clones staging area.
# A tip that is in this set (or contained by one of these refs) is safe to lose from its source.
function Get-KeptShas([string]$Dir) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in @(Invoke-Git $Dir @('for-each-ref', '--format=%(refname) %(objectname)'))) {
        $name, $sha = $line -split ' '
        if ($name -notlike 'refs/clones/*') { [void]$set.Add($sha) }
    }
    , $set
}

# 'exact' = a kept ref points straight at $Sha; 'ancestor' = a kept ref contains it; 'none' = it would be lost.
# --contains errors on non-commits (a tag pointing at a blob); those only count if matched exactly.
function Test-Covered([string]$Dir, [string]$Sha, $KeptShas) {
    if ($KeptShas.Contains($Sha)) { return 'exact' }
    $names = @(Invoke-Git $Dir @('for-each-ref', '--format=%(refname)', '--contains', $Sha))
    if ($script:GitExit -eq 0 -and @($names | Where-Object { $_ -notlike 'refs/clones/*' }).Count -gt 0) { 'ancestor' } else { 'none' }
}
