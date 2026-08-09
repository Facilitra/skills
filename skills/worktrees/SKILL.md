---
name: git-worktrees
description: 'Create, use and clean up git worktrees in a consistent, reproducible way, with a fixed location, sanitized names and guaranteed removal when the task ends. ALWAYS use this skill whenever a worktree shows up in the conversation or in the plan, for example when the user says "worktree", "árbol de trabajo", "make a separate branch", "work on another branch in parallel", "set up an environment for this ticket or PR", "try this without touching my working copy", or whenever you are about to run git worktree add, remove, list or prune yourself. Use it also to clean up existing mess, such as forgotten or duplicated worktrees, broken names created from PowerShell, or worktrees scattered across random directories.'
---

# Tidy git worktrees

A badly managed worktree does not fail loudly. It just sits there eating disk, confusing the IDE indexer and leaving orphan branches nobody dares delete months later. The three failure modes this skill removes are always the same: **improvised location**, **name invented on the spot** and **no cleanup at the end**.

The fix is to take all three decisions away from in-the-moment judgment. The scripts `wt.sh` (bash / Git Bash / WSL / macOS / Linux) and `wt.ps1` (PowerShell 5.1+) compute the path, sanitize the name, and refuse to delete unsaved work.

## Locating the scripts

They ship beside this file, which is **not** the directory you are working in. Resolve the path once at the start and reuse the variable; a bare `scripts/wt.sh` resolves against the user's project and will not be found.

```bash
# bash / Git Bash / WSL / macOS
WT=$(ls "$CLAUDE_PLUGIN_ROOT"/skills/worktrees/scripts/wt.sh \
        ~/.claude/plugins/marketplaces/*/skills/worktrees/scripts/wt.sh \
        skills/worktrees/scripts/wt.sh 2>/dev/null | head -1)
```

```powershell
# PowerShell
$wt = @("$env:CLAUDE_PLUGIN_ROOT\skills\worktrees\scripts\wt.ps1",
        "$HOME\.claude\plugins\marketplaces\*\skills\worktrees\scripts\wt.ps1",
        'skills\worktrees\scripts\wt.ps1') |
      ForEach-Object { Get-ChildItem $_ -EA SilentlyContinue } |
      Select-Object -First 1 -ExpandProperty FullName
```

The last candidate in each list covers working inside this repo itself. If none resolves, skip to *If the scripts are unavailable* at the bottom rather than improvising a path.

## Golden rule

**Never run `git worktree add` directly.** Assembling the path by hand inside a command is exactly where unresolved expansions, stray newlines and NTFS-illegal characters sneak in. Call the script and use the path it prints.

```bash
# bash / Git Bash / WSL / macOS
P=$(bash "$WT" new "login-oauth" --task "issue #412")
cd "$P"
```

```powershell
# PowerShell
$p = & $wt new "login-oauth" --task "issue #412"
Set-Location $p
```

`new` prints **only the absolute path** on stdout (warnings go to stderr), so it is safe to capture into a variable. If the worktree already exists it is reused rather than duplicated.

## Where worktrees live

Never inside the repo (it dirties the tree and triggers watchers and indexers) and never in `/tmp` or on the desktop. The root is resolved by precedence, and both scripts compute it identically:

1. `$AGENT_WT_ROOT/<repo-name>` if that environment variable is set.
2. The `root` key of `<repo>/.agent/worktrees.json`, if the repo defines one.
3. Default: `<repo-parent>/.worktrees/<repo-name>/`.

With the repo at `C:\dev\tienda`, the worktree for ticket 412 ends up at `C:\dev\.worktrees\tienda\login-oauth`. Query the active root with `wt root` instead of assuming it.

## Names

The script sanitizes whatever name you pass: lowercase, `a-z0-9-` only, no accents or spaces, collapsed dashes, 48 characters max, no trailing dot or dash, and a `wt-` prefix for Windows reserved names (`con`, `nul`, `aux`, `com1`…). The branch is `agent/<slug>` unless you pass `--branch`.

| What you ask for | Directory | Branch |
|---|---|---|
| `"Feature/Login API!!"` | `feature-login-api` | `agent/feature-login-api` |
| `"fix #412: crash on exit"` | `fix-412-crash-on-exit` | `agent/fix-412-crash-on-exit` |
| `"CON"` | `wt-con` | `agent/wt-con` |

Pick short names describing the **task**, not the date or the model: `login-oauth`, `fix-412`, `spike-cache-redis`.

## Full lifecycle

A worktree is disposable material. Creating without removing is what produces the accumulated mess, so cleanup is part of the task, not an optional extra.

**1. Create** — from the main repo, stating the base if it is not the current branch:

```bash
P=$(bash "$WT" new fix-412 --from main --task "crash on sign-out")
cd "$P"
```

**2. Work** — inside the worktree, with plain git. Remember dependencies are not inherited: `node_modules`, `.venv`, `.env`, `target/` and friends are not there, and ignored files are not either. Install what you need inside the worktree, and read the next section before you consider linking anything.

**3. Close out** — before deleting anything, secure the work: commit and push the branch, or discard it deliberately. `wt rm` refuses to delete when there are uncommitted changes or unpushed commits; that refusal is a signal, not an obstacle to route around with `--force` without looking.

**4. Remove** — when the task is done, always:

```bash
bash "$WT" rm fix-412                    # removes the worktree, keeps the branch
bash "$WT" rm fix-412 --delete-branch    # also deletes the local branch
```

Removing the worktree you are currently standing in is fine: both scripts run git against the main repo, and `wt.ps1` steps your shell out first, because Windows locks a directory that is any process's working directory and would otherwise refuse with "Permission denied".

**Before calling a task finished**, run `wt list` and confirm none of your worktrees is left hanging around. If you deliberately leave one (because the work continues tomorrow, or the user wants to review it), **say so explicitly in your final summary**, with its path and branch. A worktree that silently survives is exactly the problem this skill exists to solve.

## Never link node_modules into a worktree

The tempting shortcut is to symlink or junction the main repo's `node_modules` into the new worktree to skip an install. **Do not do it.** On Windows a recursive delete follows junctions: `Remove-Item -Recurse`, `rm -rf`, the IDE's "delete folder", the cleanup step of a build script — any of them will walk through the link and empty the *target*, destroying the main repo's `node_modules` while appearing to delete only the worktree. The same applies to `.venv`, `target/`, `vendor/` and any other shared heavy directory.

Install dependencies inside the worktree instead. If reinstalling is too slow, share through a mechanism designed for it, which is safe because nothing points into your working copies:

- **pnpm** — its content-addressable store makes a second install nearly free. Best option if the project allows it.
- **npm/yarn cache** — `npm ci` against a warm cache is far quicker than a cold install; `npm config get cache` shows where it lives.
- **A dedicated volume or per-worktree install.** Slower, always correct.

Both scripts defend against this even when someone has already created the link: `wt rm`, `wt clean` and `wt doctor --fix` **delete the links themselves before removing anything recursively**, so the target is left untouched. `wt doctor` also reports any links it finds inside a worktree. This defence only covers deletions that go through the scripts — a manual `rm -rf` or `Remove-Item -Recurse` on a worktree containing a junction is still destructive, which is the reason the golden rule says to go through the scripts.

If a main `node_modules` has already been wiped, the damage is recoverable: reinstall from the lockfile (`npm ci`, `pnpm install --frozen-lockfile`, `yarn install --immutable`). Say so plainly to the user rather than quietly reinstalling, because they will want to know why their install disappeared.

## Cleaning up existing mess

When the user complains about lost, duplicated or broken worktrees, always start with the diagnosis:

```bash
bash "$WT" doctor          # reports, changes nothing
bash "$WT" doctor --fix    # relocates misplaced ones, removes safe orphans
```

`doctor` detects four things: worktrees outside the agreed root (relocated with `git worktree move`), orphan directories with no registered worktree, names with characters that are invalid or reserved on Windows, and stale registry entries. It never moves a worktree with uncommitted changes, and never deletes a directory containing a `.git` entry — those get reported so you can decide.

For the periodic sweep:

```bash
bash "$WT" clean                        # dry run: shows what it would delete
bash "$WT" clean --merged --yes         # deletes only clean, already-merged ones
bash "$WT" clean --older-than 14 --yes  # and only those older than 14 days
```

`clean` without `--yes` deletes nothing. A worktree it refuses to remove is skipped and reported, not fatal: the sweep continues and the count of skipped ones is printed at the end. **Show the dry-run output to the user before running the real deletion**, especially the first time in a repo: there may be work there that only they can judge.

## PowerShell

This is where broken names are born. Read `references/powershell.md` before touching worktrees on Windows, or as soon as you see a directory with an absurd name (`$(git`, `--porcelain`, a name with a trailing newline). Emergency summary:

- `$(command)` is not bash substitution in PowerShell. Written bash-style, you get a directory literally named after that unresolved expansion.
- Git output carries a trailing `\r` on Windows: pasting it into a path yields names with an invisible character that nothing can then delete.
- `&&` does not chain commands in PowerShell 5.1: the second half runs even when the first half failed.
- Long path plus `node_modules` blows past the 260-character limit. Keep the root short (`C:\wt` via `AGENT_WT_ROOT`) when that bites.

## Edge cases

See `references/edge-cases.md` for submodules, Git LFS, hooks, several agents working in parallel on the same repo, worktrees on already-checked-out branches, and what to do when `git worktree remove` fails because a process holds the directory locked.

## If the scripts are unavailable

In an environment where you cannot run the scripts, apply the same rules by hand: compute the root (`<repo-parent>/.worktrees/<repo>/`), sanitize the name yourself, create with `git worktree add -b agent/<slug> <root>/<slug> <base>`, check with `git -C <path> status --porcelain` before deleting, and close with `git worktree remove <path> && git worktree prune`. The convention matters more than the tool.
