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

**Better still:** `.\wt.ps1 new "repo-fix"`, which does this and sanitizes the name.

## 2. Carriage returns glued to the path

```powershell
$root = git rev-parse --show-toplevel     # may carry a trailing "\r"
git worktree add "$root/../wt/foo" -b foo # directory with an invisible CR at the end
```

Git output on Windows can carry `\r`. A name ending in `\r` looks normal in the console, but `Remove-Item` and Explorer choke on it, and `git worktree remove` cannot find it by name.

**Fix:** always `.Trim()` any git output that will become part of a path. `wt.ps1` does this in `Get-GitLines`.

## 3. Mixed `/` and `\` separators

Git accepts both separators, but `git worktree list` returns the canonical form, which may not match the string you used at creation time. Comparing paths as plain text then fails (which is why `wt.ps1` normalizes with `[System.IO.Path]::GetFullPath()` before comparing). Use `Join-Path`, never `+ '/' +` concatenation.

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
powershell -ExecutionPolicy Bypass -File .\scripts\wt.ps1 list
```

If the user wants something permanent, it is their call: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## 9. Quick check before trusting it

On a fresh machine, the smoke test is three commands that change nothing:

```powershell
.\scripts\wt.ps1 root
.\scripts\wt.ps1 list
.\scripts\wt.ps1 doctor
```

If all three answer with sensible paths, the rest of the flow will work.
