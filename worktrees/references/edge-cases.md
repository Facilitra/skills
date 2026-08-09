# Edge cases

## The branch is already checked out elsewhere

Git refuses to have the same branch in two worktrees at once and fails with a message about it already being in use. Options, depending on what you actually want:

- If you meant to work on that branch, go to the worktree that already has it: `wt list` tells you which.
- If you meant to branch off it, create a new branch from there: `wt new my-task --from that-branch`.
- If you genuinely need its content without the branch, `git worktree add --detach <path> <ref>`.

Never use `--force` to bypass this protection: you would end up with two trees fighting over the same branch.

## `git worktree remove` fails because the directory is in use

Typical on Windows: the IDE, a running `node`/`vite`, an antivirus or a terminal open inside the worktree holds a lock. Before forcing anything, close whatever is using it. If it still fails:

```bash
git worktree remove --force <path>   # if still locked, delete the directory manually
git worktree prune                   # clean git's registry after a manual deletion
```

`prune` is what makes git stop believing in a worktree that no longer exists. If someone deleted directories by hand, `prune` (or `wt doctor`) is the repair.

## Worktree marked as `locked`

A worktree on removable or network storage may be locked deliberately (`git worktree lock`). `remove` will fail until it is unlocked:

```bash
git worktree unlock <path>
```

Check why it was locked first: `git worktree list --porcelain` shows the reason if one was recorded.

## Submodules

New worktrees do not initialize submodules. Inside the freshly created worktree:

```bash
git submodule update --init --recursive
```

Expect this to duplicate submodule content on disk for every worktree.

## Git LFS

LFS objects are shared with the main repository, but the worktree needs to materialize its pointers:

```bash
git lfs pull
```

If you see files that look like text with an `oid sha256:` inside, this is why.

## Dependencies and ignored files

A worktree contains only tracked content. No `node_modules`, `.venv`, `target/`, `.env`, or any ignored file. This surprises people most with `.env`: the app runs in the main repo and fails in the worktree because configuration is missing, not because of the code.

Copy what is needed explicitly (`cp ../repo/.env .`) and mention it to the user, because copying secrets into a new directory is their decision, not yours.

For dependencies, **install inside the worktree; never symlink or junction a shared `node_modules` into it.** Two independent reasons:

1. **Deletion hazard.** A recursive delete follows the link and empties the target, so removing the worktree destroys the main repo's `node_modules`. The scripts strip links before deleting for exactly this reason, but a manual `rm -rf` still bites.
2. **Correctness.** Packages that compile native binaries, and tooling that resolves paths through `realpath` (bundlers, jest, eslint plugin resolution), misbehave when `node_modules` lives outside the project root.

If installs are too slow, share through a store rather than a link: pnpm's content-addressable store, or a warm npm/yarn cache with `npm ci`. Both give most of the speed with none of the risk.

The same applies to `.venv`, `target/`, `vendor/`, `.gradle` and any other heavy shared directory.

## Several agents in parallel on the same repo

This is the ideal use case for worktrees, with two cautions:

- **One worktree per task, each with its own branch.** Names derived from the task, not from the agent or the timestamp.
- **The index is per worktree, but the object store is shared.** Operations that rewrite history or touch shared refs (`git gc --prune`, `git reflog expire`, `filter-branch`, rebasing branches someone else is using) affect everyone. If you must do one, announce it and do it when no other worktrees are active.

Ports collide too: if every worktree starts a dev server on 3000, the second one fails. Assign distinct ports.

## Worktrees inside the repository

You will sometimes find worktrees created at `<repo>/worktrees/something` or similar. This is a bad idea even when gitignored: IDE watchers, linters, recursive `find`/`grep` and build tooling all walk that tree and duplicate work, and some scripts end up indexing the project inside itself. `wt doctor --fix` relocates them outside with `git worktree move`.

## Bare repositories

In a bare repo (`repo.git`) there is no main working directory. The convention still holds: the default root sits as a sibling of the bare directory. Check with `wt root` before assuming anything, and note that `wt doctor` counts worktrees excluding the first entry in the list, which in a bare repo is not a usable tree.

## When the user wants a different convention

If a repo has its own agreed structure, do not fight it: write the root into `<repo>/.agent/worktrees.json` and the whole team (and every agent) will follow it.

```json
{
  "root": "../trees"
}
```

Absolute, or relative to the repo. `$AGENT_WT_ROOT` overrides it per machine, which is useful on Windows to keep paths short.
