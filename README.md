# Facilitra skills

Source of truth for shared [Claude Code](https://claude.com/claude-code) skills.

| Directory | Invoke as | What it does |
|---|---|---|
| [`skills/worktrees`](skills/worktrees/) | `/facilitra-skills:git-worktrees` | Create, use and clean up git worktrees in a fixed location, with sanitized names and guaranteed removal. Ships `wt.sh` and `wt.ps1`. |
| [`skills/mapping-architecture`](skills/mapping-architecture/) | `/facilitra-skills:mapping-architecture` | Map, document and diagram a codebase's architecture into a standalone HTML report. |

Claude also picks either one up on its own when a task matches; the explicit command is just for forcing it.

The command name comes from the `name:` field in each `SKILL.md`, which is why `skills/worktrees` is invoked as `git-worktrees`. The directory name is not the command name.

`mapping-architecture` will use `superpowers:dispatching-parallel-agents` and the `artifact-design` skills when they are present, and works without them. Nothing here requires another marketplace.

## Install

This repo is a Claude Code plugin marketplace. In Claude Code:

```
/plugin marketplace add Facilitra/skills
/plugin install facilitra-skills@facilitra
```

Update to the latest published version with `/plugin marketplace update facilitra`.

To install for everyone on a project automatically, commit this to the project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "facilitra": {
      "source": { "source": "github", "repo": "Facilitra/skills" }
    }
  },
  "enabledPlugins": { "facilitra-skills@facilitra": true }
}
```

## Contributing

Edit here, commit, push, and bump `version` in `.claude-plugin/marketplace.json`. Installed copies only update when that string changes. Validate before pushing:

```
claude plugin validate .
```

`wt.sh` and `wt.ps1` are covered by `.github/workflows/smoke.yml`, which runs the whole lifecycle on Windows, Linux and macOS and asserts on what the commands print, not just their exit codes. Both scripts have shipped bugs that exited 0 while reporting nonsense, so add a case there for anything you fix.

Do not keep a hand-copied or symlinked duplicate under `~/.claude/skills/`; it shadows the plugin copy.

## License

[MIT](LICENSE)
