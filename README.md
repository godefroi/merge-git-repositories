# Merging git clones

PowerShell scripts for one specific mess: you have a pile of git clones, many of them copies of the same repo made at different times (backups, old drives, "copied from old laptop"), the remotes are gone, and you want one repository per project that holds everything you actually have. Then you want to delete the clones and be sure nothing was lost.

Nothing here touches the clones. Every script reads them; results go into new bare repositories.

## What you end up with

One bare repo per project, with:

| Refs | Contents |
|---|---|
| `refs/heads/*`, `refs/tags/*` | Branches and tags, with the longest history winning when clones disagree only by length |
| `refs/diverged/<clone>/*` | The losing side when two clones really diverged (see below) |
| `refs/wip/<clone>` | One commit per clone holding its uncommitted work, parented on that clone's own HEAD |

A verifier proves, per source clone, that every ref tip and any uncommitted work made it into the target.

## What it does not carry

Ignored files, reflogs, unreachable commits, files hidden with assume-unchanged or skip-worktree, submodules (`.git/modules`), LFS objects, linked worktrees, and shallow clones (they're skipped, because their root commits are unreliable). Of these, the first four are deliberate. The rest simply aren't handled, so check your clones for them first.

A superseded annotated tag also loses its tag object (tagger, date, message) when the tag name moves to a newer commit. The commit it pointed at is kept. The verifier lists these separately.

## Requirements

PowerShell 7 and git. Developed on Windows with PowerShell 7.6 and git 2.54, run against about a hundred clones on a network share. Not tried on Linux or macOS.

## Workflow

Run everything from a working folder (the scripts write JSON files there). Paths below assume the scripts are on your path or you prefix them.

**1. List your clones and collect facts about each.** `repos.txt` is one path per line.

```powershell
Get-Content repos.txt | .\Get-GitRepoStatus.ps1 -JsonPath status.json | Out-Null
```

Records remotes, root commits, ref and stash counts, tracked and untracked change counts, and whether it's shallow or bare. Paths that don't exist are recorded as such.

**2. Group the clones.** Clones are in the same group if they share any root commit. This works when remotes are missing, and it copes with histories that were merged together at some point (several roots).

```powershell
.\Group-GitRepos.ps1 -StatusPath status.json -JsonPath groups.json
```

Skipped repos (missing path, no commits, shallow) come out as warnings. Each group gets an `Id`.

**3. Turn the groups into a plan and read it.** By default a group becomes one target repo. Groups that bridge things that are really separate (a shared template, a repo that absorbed others) can be split by each clone's own `origin` URL.

```powershell
.\New-GitMergePlan.ps1 -GroupsPath groups.json -PlanPath plan.json `
    -SplitByRemote 0123456789ab,abcdef012345 `
    -UrlAliases @{
        'github.com/acme/widget'          = 'widget'
        'gitlab.example.com/old/widget'   = 'widget'   # same repo, different host: one target
    }
```

- `-SplitByRemote`: group ids to split by remote URL.
- `-UrlAliases`: normalized URL (lowercase, no scheme, no `user@`, no `.git`) to target name, for URLs that are really the same repo.
- `-Hold`: group ids to leave undecided; they're marked `held` and skipped by the later steps.

The plan is a JSON array of targets with their clones. Target names come from the remote URL's last segment, or the folder name when there is no remote. Edit names in the file if you don't like them. The script warns about name collisions and appends `-2`.

**4. Build.** Dry run first.

```powershell
.\Build-GitMerge.ps1 -PlanPath plan.json -OutputRoot .\_merged_repos -WhatIf
.\Build-GitMerge.ps1 -PlanPath plan.json -OutputRoot .\_merged_repos -ReportPath build_report.json
```

Creates `<name>.git` for each target, fetches every clone into a staging area (`refs/clones/<id>/*`), then collapses the staging refs into the real ones. `-Target` takes name patterns, `-Rebuild` replaces an existing target. Anything that diverged is listed in the report.

**5. Look at what's uncommitted (optional).**

```powershell
.\Get-UntrackedFiles.ps1 -PlanPath plan.json | ConvertTo-Json -Depth 5 | Set-Content untracked.json
```

Lists each clone's untracked, non-ignored files with size and content hash. Delete junk (build output, generated docs) from the sources before the next step if you don't want it kept. Tracked changes show up in `git status` as usual.

**6. Capture uncommitted work.**

```powershell
.\Capture-GitWip.ps1 -PlanPath plan.json -OutputRoot .\_merged_repos | ConvertTo-Json | Set-Content wip_report.json
```

Each clone with uncommitted changes gets one commit (tracked changes plus untracked files that aren't ignored) on top of its own HEAD, as `refs/wip/<clone>`. Within a target, a clone is skipped when everything it has (path, mode and content) is already in an earlier clone's commit. A clone that is captured is captured in full. Takes `-WhatIf`, `-Target`, `-Rebuild`.

**7. Verify.**

```powershell
.\Test-GitMerge.ps1 -PlanPath plan.json -OutputRoot .\_merged_repos | ConvertTo-Json -Depth 4 | Set-Content verify_report.json
```

One row per source clone. `Pass` means:

- every ref tip in the clone (and a detached HEAD) is a kept ref or an ancestor of one in the target;
- `git fsck --connectivity-only` is clean on the target;
- uncommitted work is either in that clone's `refs/wip` commit (same tree as the working tree now) or entirely covered by another clone's.

A clone whose folder you've already deleted shows as "source missing" and doesn't pass.

**8. Finalize and verify again.**

```powershell
.\Finalize-GitMerge.ps1 -PlanPath plan.json -OutputRoot .\_merged_repos
.\Test-GitMerge.ps1 ...   # same as step 7
```

Deletes the staging refs, expires reflogs and prunes. After this, `Capture-GitWip.ps1` can't extend a target (it needs the staged HEAD); rebuild the target instead. Verifying again after finalize catches anything that only the staging refs were holding on to.

**9. Delete the sources yourself.** The scripts never do. Keep the originals until the second verification passes and you've looked at a few targets.

## How conflicts are resolved

For a ref name that exists in several clones (a clone's `heads/x` and its `origin/x` both count as candidates for `refs/heads/x`; other remotes' refs stay under `refs/remotes/<remote>/`):

1. If one tip contains all the others, it wins. The rest are ancestors, so no commits are lost.
2. If tips don't contain each other, the one with the newest commit date keeps the plain name and the others go to `refs/diverged/<clone>/<original name>`. Nothing is guessed away; check the build report and decide.
3. A name that can't coexist with another (`foo` and `foo/bar`) has the shorter one moved to `refs/diverged`.
4. A clone's detached HEAD that no kept ref contains is saved as `refs/diverged/<clone>/HEAD`.

## Scripts

| Script | Job |
|---|---|
| `Get-GitRepoStatus.ps1` | Per-repo facts, JSON out |
| `Group-GitRepos.ps1` | Group by shared root commits |
| `New-GitMergePlan.ps1` | Groups to a hand-editable plan |
| `Build-GitMerge.ps1` | Create targets, resolve refs |
| `Get-UntrackedFiles.ps1` | List untracked files with hashes |
| `Capture-GitWip.ps1` | Commit uncommitted work as `refs/wip/*` |
| `Test-GitMerge.ps1` | Verify per clone, PASS or FAIL |
| `Finalize-GitMerge.ps1` | Drop staging refs, prune |
| `GitMerge.Common.ps1` | Shared helpers, dot-sourced |

## Things worth knowing

- Sources are only read. `git` is run with `--no-optional-locks` so a read never refreshes a clone's index. Building a working-tree snapshot uses a throwaway index and writes only into the target.
- `Test-GitMerge.ps1` can add unreachable loose objects to a target; `Finalize-GitMerge.ps1` prunes them.
- UNC paths work (`safe.directory` is set per call). Keep target paths short: Windows' 260 character limit applies to the objects inside a target too.
- The JSON files are snapshots. If you change a clone after running step 1, rerun from there, or at least rerun `Capture-GitWip.ps1` and the verifier, which look at the working trees live.
- Run `-WhatIf` before `Build-GitMerge.ps1`, `Capture-GitWip.ps1` and `Finalize-GitMerge.ps1`.
