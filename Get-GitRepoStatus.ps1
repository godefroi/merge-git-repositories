[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string[]]$Paths,

    # When set, all results are also written to this file as a JSON array.
    [string]$JsonPath
)

begin {
    $results = [System.Collections.Generic.List[object]]::new()

    # Runs git against $repo and returns stdout lines. $LASTEXITCODE is left set for the caller.
    # safe.directory='*' bypasses ownership checks on UNC/network shares.
    function Invoke-Git($repo, [string[]]$GitArgs) {
        @(git -c safe.directory='*' -C $repo @GitArgs 2>$null)
    }
}

process {
    foreach ($repoPath in $Paths) {
        $outputObject = [PSCustomObject]@{
            Path               = $repoPath
            IsGitRepository    = $false
            Status             = "Success"
            IsBare             = $null
            IsShallow          = $null
            UncommittedChanges = 0
            TrackedChanges     = $null
            UntrackedFiles     = $null
            StashCount         = $null
            Head               = $null
            RefCount           = $null
            Remotes            = @()
            RootCommits        = @()
        }
        $results.Add($outputObject)

        if (-not (Test-Path -Path $repoPath -PathType Container)) {
            $outputObject.Status = "Path not found or inaccessible"
            $outputObject.UncommittedChanges = $null
            $outputObject
            continue
        }

        try {
            $gitOutput = git -c safe.directory='*' -C "$repoPath" status --porcelain 2>&1

            if ($LASTEXITCODE -eq 0) {
                $outputObject.IsGitRepository = $true

                $changes = @($gitOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $outputObject.UncommittedChanges = $changes.Count
                # "??" is how porcelain marks untracked files; everything else is a tracked change.
                # StartsWith, not -like: in a wildcard pattern "?" matches any character, so '??*' matched every line.
                $outputObject.UntrackedFiles = @($changes | Where-Object { $_.StartsWith('??') }).Count
                $outputObject.TrackedChanges = $changes.Count - $outputObject.UntrackedFiles

                # @() around each call: a single-line result unrolls to a string, and [0] would index its first character.
                $outputObject.IsBare = @(Invoke-Git $repoPath rev-parse, --is-bare-repository)[0] -eq 'true'
                # Roots in a shallow clone are the shallow boundary, not real roots: don't trust them for grouping.
                $outputObject.IsShallow = @(Invoke-Git $repoPath rev-parse, --is-shallow-repository)[0] -eq 'true'
                $outputObject.StashCount = @(Invoke-Git $repoPath stash, list).Count
                $outputObject.Head = @(Invoke-Git $repoPath rev-parse, HEAD)[0]
                $outputObject.RefCount = @(Invoke-Git $repoPath for-each-ref, '--format=%(refname)').Count

                $outputObject.Remotes = @(
                    Invoke-Git $repoPath config, --get-regexp, '^remote\..+\.url$' | ForEach-Object {
                        if ($_ -match '^remote\.(.+)\.url (.+)$') {
                            [PSCustomObject]@{ Name = $Matches[1]; Url = $Matches[2] }
                        }
                    }
                )

                $outputObject.RootCommits = @(Invoke-Git $repoPath rev-list, --max-parents=0, --all | Sort-Object)
            } else {
                $outputObject.Status = "Not a valid git repository or git error occurred"
                $outputObject.UncommittedChanges = $null
            }
        }
        catch {
            $outputObject.Status = "Error: $($_.Exception.Message)"
            $outputObject.UncommittedChanges = $null
        }

        $outputObject
    }
}

end {
    if ($JsonPath) {
        ConvertTo-Json -InputObject @($results) -Depth 4 | Set-Content -Path $JsonPath -Encoding utf8
    }
}
