# Worktrees from PowerShell: why the names come out broken

Almost every absurdly named directory comes from typing bash syntax into a PowerShell prompt. PowerShell does not fail: it interprets what it gets differently and **creates the directory anyway**, with the mistake baked into the name.

## 1. Command substitution

```bash
git worktree add "../wt/$(basename $(pwd))-fix" -b fix    # bash
```

In PowerShell, `$(basename $(pwd))` inside double quotes is evaluated as a PowerShell subexpression, and `basename` does not exist: the result is empty or an error, and you end up with a directory called `-fix` or worse. Inside single quotes it is taken literally and you create a directory named `$(basename $(pwd))-fix`, which also contains characters that make later deletion from Explorer awkward.

**Correct in PowerShell:**

```powershell
$name = (Split-Path -Leaf (Get-Location)) + '-fix'
$path = Join-Path 'C:\dev\.worktrees\repo' $name
git worktree add $path -b fix
```

**Better still:** `& $wt new "repo-fix"`, which does this and sanitizes the name.

## 2. Carriage returns glued to the path

```powershell
$root = git rev-parse --show-toplevel     # may carry a trailing "\r"
git worktree add "$root/../wt/foo" -b foo # directory with an invisible CR at the end
```

Git output on Windows can carry `\r`. A name ending in `\r` looks normal in the console, but `Remove-Item` and Explorer choke on it, and `git worktree remove` cannot find it by name.

**Fix:** always `.Trim()` any git output that will become part of a path. `wt.ps1` does this in `Get-GitLines`.

## 3. Mixed `/` and `\` separators

Git accepts both separators, but on Windows **`git worktree list --porcelain` answers with forward slashes** (`C:/dev/repo`) while every PowerShell path API produces backslashes (`C:\dev\repo`). Comparing the two as plain text always fails.

This is not theoretical. It shipped: `wt.ps1` compared raw git output against a backslash root, so `in_root` was permanently false. Every correctly placed worktree was reported `OUTSIDE-ROOT` by `list`, then `MISPLACED` **and** `ORPHAN` by `doctor`, `doctor --fix` tried to `git worktree move` each one onto itself forever, and `new` refused to reuse an existing worktree because the registered-path check never matched. One missing conversion, four broken commands, and a diagnostic tool that reported nothing but false positives.

Every path coming out of git is now funnelled through `ConvertTo-FullPath` (which wraps `[System.IO.Path]::GetFullPath()`) the moment it is parsed, in `Get-WorktreePaths` and `Get-MainWorktree`, so no caller ever sees the mixed form. Normalize at the boundary, not at each comparison: the comparison you forget is the one that breaks.

Use `Join-Path`, never `+ '/' +` concatenation.

## 4. `&&` and `||` in PowerShell 5.1

```powershell
git worktree add $path -b foo && cd $path     # syntax error on 5.1
```

On PowerShell 5.1 this does not even parse; on 7+ it works. If the script must run on both, chain by checking the exit code:

```powershell
git worktree add $path -b foo
if ($LASTEXITCODE -ne 0) { throw "worktree add failed" }
Set-Location $path
```

## 5. Characters NTFS rejects

Windows forbids `< > : " | ? *` and `\ /` in file names, and treats `CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9` as reserved. A branch called `feature/fix: crash` produces an invalid directory name if used as-is. Trailing dots and spaces are trouble too: Windows silently trims them, and the path you stored no longer matches the real one.

`ConvertTo-Slug` in `wt.ps1` covers all of this.

## 6. Recursive delete destroys the junction target

This is the worst failure in the whole list, because it destroys data outside the worktree.

```powershell
New-Item -ItemType Junction -Path .\wt\node_modules -Target C:\dev\app\node_modules
# ... later ...
Remove-Item -Recurse -Force .\wt        # empties C:\dev\app\node_modules
```

On PowerShell 5.1, `Remove-Item -Recurse` walks *through* junctions and directory symlinks and deletes the contents of the target. The link looks like a folder, so the recursion enters it. The main repo's `node_modules` is gone and nothing in the output suggests anything unusual happened. `rm -rf` under some Windows shells, IDE "delete folder" actions and build cleanup scripts have the same behaviour.

Delete the link, never through it:

```powershell
[System.IO.Directory]::Delete($linkPath, $false)   # removes the junction only
cmd /c rmdir "$linkPath"                           # equivalent, works on old shells
```

`wt.ps1` does this automatically in `Remove-Links`, which runs before `git worktree remove` and before any recursive deletion in `doctor --fix`. `Get-ReparsePoints` finds the links with hand-rolled recursion precisely because `Get-ChildItem -Recurse` would traverse them.

The real fix, though, is upstream: do not link `node_modules` into a worktree at all. See the corresponding section in SKILL.md.

## 7. The 260-character limit

`C:\Users\...\repo\.worktrees\some-long-name\node_modules\@scope\package\dist\...` exceeds `MAX_PATH` easily, and the failure shows up late: when installing dependencies, not when creating the worktree.

Options, least to most invasive: shorten the root with `$env:AGENT_WT_ROOT = 'C:\wt'`; shorten the slug; or enable long paths system-wide (`git config --global core.longpaths true` plus the `LongPathsEnabled` registry policy, which needs administrator rights — ask the user before touching it).

## 8. Execution policy

If `wt.ps1` will not start because of the execution policy, do not change the policy globally on your own initiative. Run the script for one session:

```powershell
powershell -ExecutionPolicy Bypass -File $wt list
```

If the user wants something permanent, it is their call: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## 9. Quick check before trusting it

On a fresh machine, the smoke test is three commands that change nothing (`$wt` resolved as in SKILL.md):

```powershell
& $wt root
& $wt list
& $wt doctor
```

Read the output, do not just check that it ran. All three exit 0 even when the answers are nonsense, which is exactly how the separator bug in section 3 survived: the failing state was a clean exit and a confidently wrong report. Specifically:

- `root` must name a directory outside the repo.
- `list` must **not** mark a worktree under that root as `OUTSIDE-ROOT`.
- `doctor` on a repo whose worktrees were all made with `wt new` must say `all clear`.

Section 10 automates exactly this.

## 10. The regression test

`.github/workflows/smoke.yml` runs the full lifecycle (`new`, reuse, reserved name, `list`, `doctor`, refuse-dirty, `rm` from inside the worktree, `clean` dry run, `clean --yes`) against both scripts, on Windows, Linux and macOS. It asserts on the text the commands print, not merely on exit codes.

Add a case there before fixing any bug you find in these scripts. Every defect listed in this file was invisible to an exit-code check.

## 11. Deleting the directory you are standing in

Windows locks a directory that is any process's working directory. `Set-Location` into a worktree, then try to remove it, and git fails with `Permission denied` on a path that is otherwise perfectly deletable. POSIX shells allow this, so the same sequence works under Git Bash and WSL and fails only on native PowerShell, which makes it easy to miss.

`Cmd-Remove` handles it: if the current location is at or under the worktree being removed, it moves back to the main repo first (setting both the PowerShell location and `[Environment]::CurrentDirectory`, since git is a child process that inherits the latter) and says so. Doing it by hand means `Set-Location` somewhere else before calling `git worktree remove`.

Same family of problem: the registry entry's path is now computed *before* the removal, because resolving it walks up through the repo root, and once cwd has been deleted that lookup fails and the entry is orphaned.
