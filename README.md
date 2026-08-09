# Facilitra skills

Source of truth for shared [Claude Code](https://claude.com/claude-code) skills.

| Skill | What it does |
|---|---|
| [`worktrees`](skills/worktrees/) | Create, use and clean up git worktrees in a fixed location with sanitized names and guaranteed removal. |
| [`mapping-architecture`](skills/mapping-architecture/) | Map, document and diagram a codebase's architecture into an HTML report. |

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

Edit here, commit, push, and bump `version` in `.claude-plugin/marketplace.json` — installed copies only update when that string changes.

Do not keep a hand-copied or symlinked duplicate under `~/.claude/skills/`; it shadows the plugin copy.
