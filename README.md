# Facilitra skills

Source of truth for shared [Claude Code](https://claude.com/claude-code) skills.

| Skill | What it does |
|---|---|
| [`worktrees`](worktrees/) | Create, use and clean up git worktrees in a fixed location with sanitized names and guaranteed removal. |
| [`mapping-architecture`](mapping-architecture/) | Map, document and diagram a codebase's architecture into an HTML report. |

## Install

Clone anywhere, then link each skill into your Claude skills directory.

**Windows (PowerShell):**

```powershell
git clone https://github.com/Facilitra/skills.git $HOME\projects\skills
foreach ($s in 'worktrees','mapping-architecture') {
  New-Item -ItemType Junction -Path "$HOME\.claude\skills\$s" -Target "$HOME\projects\skills\$s"
}
```

**macOS / Linux:**

```bash
git clone https://github.com/Facilitra/skills.git ~/projects/skills
for s in worktrees mapping-architecture; do
  ln -s ~/projects/skills/$s ~/.claude/skills/$s
done
```

`git pull` updates every linked skill. Remove an existing `~/.claude/skills/<name>` directory first if one is in the way.

## Contributing

Edit here, commit, push. Never edit the copy under `~/.claude/skills/` — it is a link.
