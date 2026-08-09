---
name: mapping-architecture
description: Use when asked to analyse, map, document, or diagram a project's architecture, produce a codebase overview, system map, onboarding page, or architecture HTML report, or to explain how an unfamiliar repository fits together.
---

# Mapping Architecture

## Overview

Produce a single self-contained HTML page describing how a codebase actually works, derived from the code rather than from its README.

**Core principle: every box, edge, and claim on the page cites a file path. No evidence, no box.**

The failure this skill exists to prevent is a beautiful, plausible, wrong page - one that renders the architecture the docs *describe* instead of the one the code *implements*. Docs go stale. Imports do not.

## The Evidence Rule

Every finding carried into the page is a record with a REQUIRED `evidence` field:

| Field | Content |
|---|---|
| `claim` | What is true, one sentence |
| `evidence` | `path/to/file.ts:42` - a real path you opened |
| `confidence` | `verified` (read the code) or `inferred` (pattern-matched only) |

Any number in a claim carries its scope, in the claim: "255 importers under `src/`, tests included".
Fan-in, file and call-site counts all move by 30% or more depending on whether tests, generated code
and dynamic imports are counted, so a bare integer is two agents' numbers silently disagreeing.

Cannot fill `evidence`? The claim does not go on the page - it goes in the Gaps section.
`inferred` findings render with a visible marker. Never silently promote inferred to verified.

## Workflow

### 1. Recon - single pass, cheap

Establish shape before spending agents. See `references/probes.md` for per-ecosystem commands.

- Manifests and lockfiles, giving languages, frameworks, dependencies
- Directory tree, 2-3 levels, with file counts
- Entry points: `main`, `index`, `bin`, manifest `scripts`, Dockerfile `CMD`
- Config: env var names, `.env.example`, CI files, IaC directories
- `git log` author and churn stats, showing where the project is alive
- README, docs, ADRs: read these LAST, and treat them as hypotheses to verify, never as source

Write recon output to a scratch file. It becomes the shared brief for step 2.

### 2. Fan out - one agent per dimension

Use superpowers:dispatching-parallel-agents. Give every agent the recon brief and the same contract: return findings as records with the three fields above.

| Dimension | Question it answers |
|---|---|
| Surfaces | What can call into this system? HTTP routes, CLI, cron, queues, webhooks, event handlers |
| Module graph | Which directories import which? Where does dependency direction reverse? |
| Data layer | Stores, schema, migrations, query hot spots, caching and invalidation |
| Integrations | Third-party services, the config var enabling each, the code path calling it |
| Pipeline | How source becomes a running process, what gates it, and which gates can actually fail |
| Health | Coupling hot spots, dead exports, oversized files, layering violations, TODO density |

Start the repo's own gates and the one-shot analysers from `references/probes.md` in the MAIN loop,
backgrounded, before dispatching anyone - they take minutes, they are the same for every dimension,
and their output belongs in the brief the agents share. Do not hand them to the Health agent to run;
that serialises them behind one agent and hides the raw output from you. Grep-derived health claims
are `inferred`; tool-derived ones are `verified` only after step 3.

Scale the fleet to the repo. Under ~200 files, do it inline and skip the fan-out.

### 3. Verify before drawing

For each finding, confirm the cited path exists and says what the claim says. Where two agents contradict each other, that contradiction is itself a finding: resolve it by reading the code, never by averaging.

**A claim about failure behaviour is verified only by causing the failure.** "Throws when the key is
absent", "returns null on timeout", "fails closed" - reading the call site proves the call exists, it
does not prove what the callee does when misconfigured. That belongs to a dependency you did not
write. Run it: one `node -e` with the variable deleted settles it in seconds. A real page shipped
"seven module-scope clients crash at import without the API key" straight from an agent; the SDK
tolerates a missing key and defers it to the first request, so the finding, its severity, and the fix
built on it were all wrong.

Drop or demote anything that fails. This step is the difference between a map and a fiction.

### 4. Build the page

Copy `references/template.html`, fill the sections, write to the path the user named. The default is
`<repo>/architecture-<short-sha>.html` - the SHA in the filename is what makes the snapshot rule below
enforceable rather than merely stated, since a later run lands beside the old one instead of tempting
you to patch it. Check that the repo ignores the pattern (`/architecture-*.html`), not just the bare
`architecture.html`, or every snapshot shows up as untracked noise.

**The page is a snapshot of one commit, and it is frozen at handoff.** The header stamps a SHA, so
every claim in it is a claim about that tree. Two rules follow:

- Corrections belong BEFORE handoff. Step 3 is where a wrong claim gets fixed or demoted. Discovering
  an error later is fine too - correct it and say so in the text - but only ever to make the page
  describe the stamped commit more accurately.
- **Never edit the page to reflect fixes made after that commit.** Writing "consolidated into a lazy
  getter" or "the runbook has been corrected" into a page stamped three commits earlier produces a
  document that matches no commit at all, which is worse than either state alone. When the code moves,
  re-run the skill and overwrite the file wholesale with a fresh SHA.

This bites hardest in exactly the session that generated the page, where fixing what the map found is
the obvious next task and the file is still open. Fix the code; leave the map alone. If a caller wants
several snapshots side by side, suffix the filename with the short SHA rather than patching one file.

Section order is the contract. Do not reorder. Do not add a section with no verified content. Do not pad a thin section with prose.

**Header** (unnumbered) - project name, one-line purpose, stack badges, commit SHA, generation date

1. **At a glance** - stat tiles: languages, file count, surfaces, external services, stores
2. **System context** - the project and everything outside it that it talks to
3. **Surfaces** - table: entry point, handler file, purpose
4. **Module map** - layered diagram plus dependency direction between layers
5. **Dependency explorer** - the interactive graph, see below
6. **Data** - stores, key entities, migration mechanism
7. **Integrations** - table: service, purpose, config var, code path
8. **Pipeline** - build, test, deploy, and the gates, marking any gate that cannot fail the build
9. **Findings** - risks and health observations, each with its evidence link
10. **Gaps** - what was not examined, plus every claim demoted for lack of evidence

Section 10 is required even when short. A page hiding its own blind spots is worse than one admitting them.

### 5. Offer to publish

The page is a local file. State the path. If the user wants a shareable URL, load `artifact-design`, then make a body-only copy - strip `<!doctype>`, `<html>`, `<head>`, `<body>`, keep the `<style>` block - and publish that with the Artifact tool.

## The dependency explorer

The template ships a working explorer. You do not write any JavaScript: you fill one JSON block, `<script type="application/json" id="graph">`.

```json
{
  "nodes": [{"id": "q", "label": "db/queries", "path": "src/db/queries", "layer": "Data", "kind": "module", "loc": 2600}],
  "edges": [["page", "q"]]
}
```

`edges` reads **[from, to] = "from depends on to"**. Get direction wrong and the whole page inverts.

What it gives the reader: click any node to re-centre it, with everything that depends on it on the left and everything it depends on on the right, both clickable, so they can walk the graph. Plus filter by name or path, filter by layer, and sort by fan-in to surface hubs.

Choosing node granularity - pick one level and hold it:

| Repo size | Node = | Typical count |
|---|---|---|
| Large | Top 2 directory levels | 15-40 |
| Medium | Individual module or file | 30-80 |
| OO-heavy | Class or interface | 30-80 |

Above ~120 nodes the explorer stops being navigable. Aggregate a level up rather than shipping a hairball. `layer` drives node colour, so keep layer names to roughly six.

Every node needs a real `path`: it is that node's evidence. Nodes render with zero edges when the import scan missed them, which is a Gaps entry, not something to hide.

## Diagrams

Write **inline SVG or HTML/CSS boxes**. Nothing else survives both contexts:

| Approach | Local file | Published Artifact |
|---|---|---|
| Inline SVG | works | works |
| HTML/CSS box layout | works | works |
| Mermaid via CDN script | works | blocked by CSP |
| Mermaid fenced block | renders as literal text | works |

The template ships CSS for layered box diagrams, which covers most layer and module maps with no SVG at all. Reach for inline SVG only when you need real edges with arrowheads, and load `artifact-diagramming` first.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Diagram redraws the README | Derive edges from imports and calls, then check the README against your diagram |
| "Probably uses X for Y" | Either open the file, or put it in Gaps |
| Every directory becomes a box | Boxes are things that run or store state, not folders |
| Page is a wall of prose | Tables and diagrams carry content; prose only connects them |
| Stale on arrival | Stamp the commit SHA in the header so a reader can tell |
| Module graph built from the manifest | That is the third-party list. The module graph comes from import statements |

## Red Flags

- Writing a section before any agent returned findings for it
- An edge on a diagram you cannot name a file for
- Citing `docs/ARCHITECTURE.md` as evidence for how the code behaves
- Gaps section empty
- Reaching for a CDN script tag
- Standing up a quality server (SonarQube and friends) when a one-shot analyser answers the question
- Health findings that are all grep, when the repo ships a lint and typecheck script you never ran
- A severity that rests on how a third-party library behaves when misconfigured, which you never ran
- Reporting a tool's headline number (cycles, clones, vulnerabilities) without classifying its items
- Editing a delivered page to say a finding is now fixed, instead of regenerating it at the new SHA
