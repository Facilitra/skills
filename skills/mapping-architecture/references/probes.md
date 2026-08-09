# Recon Probes

Cheap commands that establish repo shape before spending agents. Run the universal set, then the ecosystem set for whatever the manifests reveal.

Prefer the Grep and Glob tools over shelling out to `rg`/`find` where possible - results come back linked and scoped. The shell commands below are for aggregation (counts, sorts, git plumbing), which the tools do not do.

## Universal

```bash
# Identity and freshness - the SHA goes in the page header
git rev-parse --short HEAD && git log -1 --format='%cI'

# Where the project is alive: churn over the last year
git log --since='1 year ago' --name-only --format='' | sort | uniq -c | sort -rn | head -40

# Who built what - reveals ownership boundaries and abandoned areas
git log --format='%an' | sort | uniq -c | sort -rn | head -20

# File counts by extension, excluding vendored trees
git ls-files | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -25

# Env vars actually read by the code, not just those documented.
# The capture group keeps the name only; without -r '$1' you get ragged half-quoted matches.
rg -o 'process\.env\[?["'"'"']?(\w+)' -r '$1' --no-filename | sort -u
rg -o 'os\.environ\[["'"'"'](\w+)' -r '$1' --no-filename | sort -u
```

These assume `rg` (ripgrep). Where it is absent, `grep -rc` covers most probes with the same shape.

Directory shape: `git ls-files | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -30`. This beats `tree` because it respects gitignore automatically.

## Manifest to ecosystem

| File present | Ecosystem | Read for |
|---|---|---|
| `package.json` | Node / TS | `scripts`, `dependencies`, `workspaces`, `bin`, `type` |
| `pyproject.toml`, `requirements.txt` | Python | `[project.scripts]`, deps, tool config |
| `go.mod` | Go | module path, `require`, Go version |
| `Cargo.toml` | Rust | `[[bin]]`, `[dependencies]`, workspace members |
| `pom.xml`, `build.gradle` | JVM | modules, deps, plugins |
| `Gemfile`, `*.gemspec` | Ruby | groups, Rails engines |
| `composer.json` | PHP | `autoload.psr-4`, scripts |
| `*.csproj`, `*.sln` | .NET | project references, target framework |
| `Dockerfile`, `compose.yaml` | Any | `CMD`/`ENTRYPOINT` is the real entry point; compose services are the real topology |
| `.github/workflows/`, `.gitlab-ci.yml` | Any | the pipeline, the gates, the deploy target |
| `k8s/`, `*.tf`, `serverless.yml` | Any | runtime topology, secrets, scaling |

## Surfaces by framework

Find what can call into the system. Match on the convention, then open the file.

| Stack | Surface probe |
|---|---|
| Next.js App Router | `**/app/**/{page,route,layout}.{ts,tsx,js,jsx}`, plus `middleware.ts` or `proxy.ts` |
| Next.js Pages | `**/pages/**/*.{ts,tsx}`, `**/pages/api/**` |
| Express / Koa / Fastify | `rg '\.(get|post|put|patch|delete|all)\(' --type ts` |
| NestJS | `rg '@(Controller|Get|Post|MessagePattern|EventPattern)\('` |
| Django | `urls.py` files, `rg 'path\(|re_path\('` |
| FastAPI / Flask | `rg '@(app|router)\.(get|post|route)\('` |
| Rails | `config/routes.rb` |
| Spring | `rg '@(RestController|RequestMapping|GetMapping)'` |
| Go net/http, chi, gin | `rg '\.(HandleFunc|Get|Post|Handle)\('` |
| gRPC | `**/*.proto` service blocks |
| GraphQL | `**/*.graphql`, `rg 'type (Query|Mutation)'` |
| CLI | manifest `bin`, `[[bin]]`, `[project.scripts]`, `rg 'argparse|commander|cobra|clap'` |
| Cron / scheduled | `k8s/**/CronJob`, `rg 'cron|schedule'` in CI and IaC, `*.timer` |
| Queues / workers | `rg 'bullmq|celery|sidekiq|sqs|kafka|rabbit|pubsub'` |
| Webhooks inbound | `rg -i 'webhook|signature|hmac'` under route directories |

Non-obvious surfaces that get missed: server actions, background job registrations, SSE and WebSocket handlers, database triggers, and anything a `Dockerfile CMD` starts that is not the main app.

## Module graph

The dependency graph between *your* modules comes from import statements, never from the manifest.

```bash
# Node/TS: cross-directory imports, aggregated into edges
rg -o "from ['\"](@/|\.\./)[^'\"]+" -r '$0' src --no-filename | sort | uniq -c | sort -rn | head -40

# Python
rg -o '^(from|import) [\w.]+' --no-filename | sort | uniq -c | sort -rn | head -40

# Go
rg -o '"<module-path>/[\w/]+"' --no-filename | sort | uniq -c | sort -rn | head -40
```

Three traps when turning raw import lines into nodes and edges, each of which silently produces a
wrong-but-plausible graph:

1. **A specifier can name a directory barrel.** `@/db/schema` is `src/db/schema/index.ts`, not a file
   called `schema`. Treat a target as a directory when it stats as one, or the repo's most-imported
   modules collapse into their parent and read as isolated.
2. **A flat edge-weight floor deletes small nodes.** Edge weight scales with the source group's file
   count, so a one-file node (`proxy.ts`, `auth.ts`) never clears a floor of 3 and renders with no
   edges at all. Waive the floor when the source is one or two files.
3. **Root-level modules are not part of the neighbouring package.** `src/auth.ts` is its own node; if
   your path parser has no branch for depth-2 paths it will silently fold into whatever bucket is first.

Aggregate to directory pairs, then look for the two things that matter:

- **Reversed edges** - a lower layer importing an upper one (`db/` importing `components/`). These are the layering violations that go in Findings.
- **Hubs** - one module imported by most others. Note its fan-in count; it is the file that cannot be changed cheaply.

Dedicated tools when available and worth the setup: `madge --circular`, `dependency-cruiser`, `go mod graph`, `jdeps`, `pydeps`.

## Data layer

| Signal | Probe |
|---|---|
| Schema | `**/schema.{ts,py,rb,sql}`, `**/models/**`, `**/entities/**`, `*.prisma` |
| Migrations | `**/migrations/**`, `**/alembic/**`, `db/migrate/**` - count them, read the newest 3 and the oldest 1 |
| ORM in use | manifest deps: drizzle, prisma, typeorm, sqlalchemy, activerecord, gorm, hibernate |
| Raw SQL | `rg -i 'select .* from|insert into' --type-not sql` |
| Caches | `rg -i 'redis|valkey|memcach|revalidateTag|cacheTag|@cache'` |
| Blob storage | `rg -i 's3|minio|gcs|blob|bucket'` |

Migration count and date span tell you the schema's real age. A schema file with no migrations means it is generated or hand-applied, which is a finding.

## Health

```bash
# TODO/FIXME/HACK density by directory.
# gsub normalises the backslash paths ripgrep emits on Windows; the p[2] ternary keeps repo-root files
# from collapsing into a bogus "file/" bucket.
rg -c 'TODO|FIXME|HACK|XXX' \
  | awk -F: '{n=$1; gsub(/\\/,"/",n); split(n,p,"/"); d=(p[2] ? p[1]"/"p[2] : p[1]); c[d]+=$2} END {for (d in c) print c[d], d}' \
  | sort -rn | head -20

# Files over 500 lines. xargs batches, so wc emits one "total" line per batch - drop them or they
# sort straight to the top and you report a batch subtotal as your largest file.
git ls-files | xargs wc -l 2>/dev/null | rg -v ' total$' | sort -rn | awk '$1 > 500' | head -30

# Suppressions - each one is a deliberate exception worth naming
rg -c 'eslint-disable|@ts-ignore|@ts-expect-error|# type: ignore|#\[allow\(|nolint' | sort -t: -k2 -rn | head -20

# Test-to-source ratio
echo "tests: $(git ls-files | rg -c '(test|spec)' || echo 0) / total: $(git ls-files | wc -l)"
```

Dead exports need a real tool - `knip`, `ts-prune`, `vulture`, `deadcode`. Without one, mark dead-code claims `inferred` or leave them out. Grep cannot prove absence of use across dynamic dispatch.

## Quality signals

Everything above is grep, so every claim it produces is `inferred`. One-shot analysers turn the
expensive half of the Health dimension into `verified` findings. Run these only when Health is in
scope, and only the ones matching the ecosystem - each costs a minute or two.

**Run the repo's own gates first.** They are already configured, already passing or not, and their
output is the truest health signal in the repo. Never install a linter the project does not use.

```bash
<pkg-manager> run lint; <pkg-manager> run typecheck; <pkg-manager> test
```

Then the analysers the repo lacks. All are one-shot, machine-readable, and leave nothing running:

| Signal | Node / TS | Python | Go | Rust |
|---|---|---|---|---|
| Cycles | `npx -y madge --circular --extensions ts,tsx --ts-config tsconfig.json src` | `pydeps --show-cycles` | `go vet ./...` | `cargo clippy` |
| Dead code | `npx -y knip --reporter json` | `vulture .` | `deadcode ./...` | `cargo +nightly udeps` |
| Duplication | `npx -y jscpd --min-lines 25 --min-tokens 80 --reporters consoleFull --ignore "**/__tests__/**" src` | same (`jscpd` is language-agnostic) | same | same |
| Complexity | `npx -y typhonjs-escomplex` or file length | `radon cc -s -a` | `gocyclo -over 15 .` | `cargo clippy::cognitive_complexity` |

`jscpd` covers duplication for every language, which is the one metric usually reached for SonarQube.
Its flags drift between releases - it is `--reporters` (plural), `--ignore` takes one comma-separated
string, there is no `--gitignore`, and the path goes last. A bad flag exits 2 with a usage dump, so
check the exit code rather than reading an empty clone list as a clean result. Scope it to source
extensions: run against `src` and ignore `**/__tests__/**`, or prose files produce junk clones -
on a real repo it "found" a README duplicating itself at lines 52-105 against lines 52-105.

**A cycle count is a lead, not a finding.** `madge` counts `import type` and dynamic `await import()`
as edges, and both are the standard ways to *break* a cycle: a lazy import defers module init, a
type-only import is erased at compile time. Neither deadlocks and neither couples at runtime. Open
every reported cycle and classify it before any of them reaches the page - on a real repo six of
seven were benign, and "7 circular dependencies" would have been the plausible-but-wrong headline
this skill exists to prevent. Same caution for reversed edges in the module graph: check for
`import type` before calling one a layering violation.

Change hotspots need no tooling at all: intersect the churn list (Universal) with the >500-line list
(Health). A file in both is where complexity and change rate compound, and it belongs in Findings.

**Gate audit** - which gates exist is section 8; which of them actually block is a finding:

```bash
rg -n 'continue-on-error|\|\| true|allow_failure|--passWithNoTests|--no-verify|\|\| exit 0' \
  .github .gitlab-ci.yml Makefile package.json 2>/dev/null
```

A gate that cannot fail the build is not a gate. Name each one in Findings with its file and line.

Evidence for a tool-derived finding is still a path - cite the worst offender the tool named, not the
tool. Name the command in the finding's prose so a reader can re-run it. A tool that errored out is a
Gaps entry, never a silent omission.

**Not SonarQube.** A server, a scanner pass, project provisioning and a token, for issue lists that
these commands already produce in seconds. Use it only when the repo already runs one - then read its
existing findings through `/api/issues/search` instead of standing up your own.

## Cost control

Recon should stay under a few dozen tool calls. If a probe returns thousands of lines, tighten the path scope rather than piping to `head` and pretending you saw the rest - and record what you truncated for the Gaps section.
