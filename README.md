# Facilitra skills

Source of truth for shared [Claude Code](https://claude.com/claude-code) skills.

| Skill | Invoke as | What it does |
|---|---|---|
| [`worktrees`](skills/worktrees/) | `/facilitra-skills:git-worktrees` | Create, use and clean up git worktrees in a fixed location, with sanitized names and guaranteed removal. Ships `wt.sh` and `wt.ps1`. |
| [`mapping-architecture`](skills/mapping-architecture/) | `/facilitra-skills:mapping-architecture` | Map, document and diagram a codebase's architecture into a standalone HTML report. |

Claude also picks either one up on its own when a task matches; the explicit command is just for forcing it.

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

Do not keep a hand-copied or symlinked duplicate under `~/.claude/skills/`; it shadows the plugin copy.

## License

[MIT](LICENSE)
