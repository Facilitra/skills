#!/usr/bin/env bash
# wt.sh - deterministic git worktree management for agents.
# Usage: ./wt.sh <command> [args]   |   ./wt.sh help
set -uo pipefail

VERSION="1.1.0"

# ---------------------------------------------------------------- helpers

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

json_escape() {
  # escape a string for JSON without depending on jq
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_get() {
  # json_get <file> <key> -> value of a top-level string key
  [ -f "$1" ] || return 1
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

normalize_path() {
  # Lexically normalize ../ and ./ without relying on realpath or on the path
  # existing. Needed so comparisons against `git worktree list` line up.
  local p=$1 part res
  local -a parts=() out=()
  case "$p" in /*|[A-Za-z]:*) ;; *) p="$PWD/$p" ;; esac
  IFS='/' read -ra parts <<< "$p"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) continue ;;
      ..) [ ${#out[@]} -gt 0 ] && unset "out[$(( ${#out[@]} - 1 ))]" && out=("${out[@]}") ;;
      *) out+=("$part") ;;
    esac
  done
  res=$(IFS=/; printf '%s' "${out[*]-}")
  case "$p" in
    [A-Za-z]:*) printf '%s' "$res" ;;
    *) printf '/%s' "$res" ;;
  esac
}

repo_root() {
  local r
  r=$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || \
    die "not inside a git repository"
  # if we are already inside a worktree, jump to the main repo
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$common" in
    */.git) printf '%s' "${common%/.git}" ;;
    *)      printf '%s' "$r" ;;
  esac
}

default_branch() {
  local d=${1:-.} b
  b=$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) && \
    { printf '%s' "${b#origin/}"; return; }
  for b in main master develop; do
    if git -C "$d" show-ref --verify --quiet "refs/heads/$b"; then printf '%s' "$b"; return; fi
  done
  git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Worktree root. Precedence: AGENT_WT_ROOT > .agent/worktrees.json > repo sibling.
wt_root() {
  local repo cfg root
  repo=$(repo_root) || exit 1
  if [ -n "${AGENT_WT_ROOT:-}" ]; then
    root="$AGENT_WT_ROOT/$(basename "$repo")"
  else
    cfg="$repo/.agent/worktrees.json"
    root=$(json_get "$cfg" root 2>/dev/null || true)
    if [ -n "$root" ]; then
      case "$root" in
        /*|[A-Za-z]:*) : ;;                 # absolute
        *) root="$repo/$root" ;;            # relative to the repo
      esac
    else
      root="$(dirname "$repo")/.worktrees/$(basename "$repo")"
    fi
  fi
  # normalize without resolving symlinks (so network paths keep working)
  root=$(normalize_path "$root")
  printf '%s' "${root%/}"
}

registry_dir() { printf '%s/.registry' "$(wt_root)"; }

RESERVED='^(con|prn|aux|nul|com[1-9]|lpt[1-9])$'

slugify() {
  local s=$1
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  s=${s//$'\r'/}
  s=$(printf '%s' "$s" | LC_ALL=C sed -e 's/[^a-z0-9]\+/-/g' -e 's/-\+/-/g' -e 's/^-//' -e 's/-$//')
  s=${s:0:48}
  s=${s%-}
  s=${s%.}
  [ -n "$s" ] || die "the name is empty after sanitizing; use letters and digits"
  if printf '%s' "$s" | grep -Eq "$RESERVED"; then s="wt-$s"; fi
  printf '%s' "$s"
}

is_dirty() { [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

list_links() {
  # Symlinks inside a worktree (does NOT descend into them, so a linked
  # node_modules is listed as one entry instead of being walked).
  find "$1" -type l 2>/dev/null
}

strip_links() {
  # Delete the LINKS themselves before any recursive removal touches the tree.
  # This is the difference between deleting a shortcut and wiping the folder it
  # points at: on Windows, recursive delete traverses junctions and empties the
  # target, which is how a shared node_modules in the main repo gets destroyed.
  local p=$1 l count=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    rm -f "$l" && count=$((count+1))
  done < <(list_links "$p")
  [ "$count" -gt 0 ] && info "unlinked $count link(s) first; their targets were left untouched"
  return 0
}

unpushed_count() {
  # Commits that only live here. With a remote: those on no remote. Without a
  # remote: those not on the base branch (otherwise everything would look
  # "unpushed" and clean/rm would never delete anything).
  local base
  if [ -n "$(git -C "$1" remote 2>/dev/null)" ]; then
    git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0
  else
    base=$(default_branch "$1")
    git -C "$1" rev-list --count HEAD --not "$base" 2>/dev/null || echo 0
  fi
}

branch_of() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }

is_merged() {
  # is_merged <path> <base>
  local head base
  head=$(git -C "$1" rev-parse HEAD 2>/dev/null) || return 1
  base=$(git -C "$1" rev-parse "$2" 2>/dev/null) || \
    base=$(git -C "$1" rev-parse "origin/$2" 2>/dev/null) || return 1
  [ "$(git -C "$1" merge-base "$head" "$base")" = "$head" ]
}

# worktree paths (one per line), excluding the main one
worktree_paths() {
  git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2
}

main_worktree() { git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1; }

age_days() {
  local p=$1 created now
  created=$(json_get "$(registry_dir)/$(basename "$p").json" created_epoch 2>/dev/null)
  [ -n "$created" ] || created=$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo 0)
  now=$(date +%s)
  echo $(( (now - created) / 86400 ))
}

# ---------------------------------------------------------------- commands

cmd_new() {
  local slug="" base="" branch="" task="" print_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) base=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      --json) print_json=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) slug=$1; shift ;;
    esac
  done
  [ -n "$slug" ] || die "usage: wt new <name> [--from <ref>] [--branch <branch>] [--task \"...\"]"

  local repo root path
  repo=$(repo_root) || exit 1
  root=$(wt_root)
  slug=$(slugify "$slug")
  path="$root/$slug"
  [ -n "$branch" ] || branch="agent/$slug"
  [ -n "$base" ] || base=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

  if [ -e "$path" ]; then
    if git -C "$repo" worktree list --porcelain | grep -Fxq "worktree $path"; then
      info "a worktree already exists at $path (reusing it)"
      printf '%s\n' "$path"; return 0
    fi
    die "$path exists but is not a registered worktree; delete it or pick another name"
  fi

  mkdir -p "$root" || die "could not create root $root"

  local out
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    out=$(git -C "$repo" worktree add "$path" "$branch" 2>&1) || die "git worktree add failed: $out"
  else
    out=$(git -C "$repo" worktree add -b "$branch" "$path" "$base" 2>&1) || die "git worktree add failed: $out"
  fi

  mkdir -p "$(registry_dir)"
  cat > "$(registry_dir)/$slug.json" <<EOF
{
  "slug": "$(json_escape "$slug")",
  "path": "$(json_escape "$path")",
  "branch": "$(json_escape "$branch")",
  "base": "$(json_escape "$base")",
  "task": "$(json_escape "$task")",
  "repo": "$(json_escape "$repo")",
  "created_epoch": "$(date +%s)",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  if [ "$print_json" = 1 ]; then
    printf '{"path":"%s","branch":"%s","slug":"%s"}\n' \
      "$(json_escape "$path")" "$(json_escape "$branch")" "$(json_escape "$slug")"
  else
    printf '%s\n' "$path"
  fi
}

cmd_list() {
  local print_json=0
  [ "${1:-}" = "--json" ] && print_json=1
  local root base p b dirty un merged first=1
  root=$(wt_root); base=$(default_branch)

  [ "$print_json" = 1 ] && printf '['
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    b=$(branch_of "$p"); [ -n "$b" ] || b="(detached)"
    dirty=false; is_dirty "$p" && dirty=true
    un=$(unpushed_count "$p")
    merged=false; is_merged "$p" "$base" && merged=true
    local inroot=false
    case "$p" in "$root"/*) inroot=true ;; esac
    if [ "$print_json" = 1 ]; then
      [ $first = 1 ] || printf ','
      first=0
      printf '{"path":"%s","branch":"%s","dirty":%s,"unpushed":%s,"merged":%s,"in_root":%s,"age_days":%s}' \
        "$(json_escape "$p")" "$(json_escape "$b")" "$dirty" "${un:-0}" "$merged" "$inroot" "$(age_days "$p")"
    else
      local flags=""
      [ "$dirty" = true ] && flags="$flags dirty"
      [ "${un:-0}" -gt 0 ] && flags="$flags unpushed=$un"
      [ "$merged" = true ] && flags="$flags merged"
      [ "$inroot" = false ] && flags="$flags OUTSIDE-ROOT"
      printf '%-50s %-28s%s\n' "$p" "$b" "${flags:+ [${flags# }]}"
    fi
  done < <(worktree_paths)
  [ "$print_json" = 1 ] && printf ']\n'
  return 0
}

resolve_path() {
  # accepts a slug or a path
  local want=$1 root p
  root=$(wt_root)
  # normalize_path, not `cd && pwd`: under Git Bash pwd answers in MSYS form
  # (/tmp/...), which does not match the C:/... paths git and wt_root use, so the
  # resolved path printed back to the user names a location they cannot find.
  if [ -d "$want" ]; then normalize_path "$want"; return 0; fi
  if [ -d "$root/$want" ]; then printf '%s' "$root/$want"; return 0; fi
  while IFS= read -r p; do
    [ "$(basename "$p")" = "$want" ] && { printf '%s' "$p"; return 0; }
  done < <(worktree_paths)
  return 1
}

cmd_rm() {
  local force=0 delbranch=0 target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --delete-branch) delbranch=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "usage: wt rm <slug|path> [--force] [--delete-branch]"
  local path b un repo
  path=$(resolve_path "$target") || die "cannot find worktree '$target' (try: wt list)"
  b=$(branch_of "$path")
  un=$(unpushed_count "$path")
  # Every git call runs against the main repo: the skill tells you to cd into the
  # worktree to work, and `git worktree remove` fails when run from inside its target.
  repo=$(repo_root)

  if [ "$force" != 1 ]; then
    is_dirty "$path" && die "'$path' has uncommitted changes. Review them with: git -C \"$path\" status. Use --force to discard them."
    [ "${un:-0}" -gt 0 ] && die "'$path' has $un unpushed commit(s) on '$b'. Push the branch or use --force."
  fi

  # Resolved BEFORE the removal: registry_dir walks up through repo_root, and if the
  # caller is standing inside the worktree being deleted, cwd no longer exists by then,
  # so the lookup fails and the entry survives as a phantom.
  local meta="$(registry_dir)/$(basename "$path").json"

  strip_links "$path"
  git -C "$repo" worktree remove ${force:+--force} "$path" || die "could not remove $path"
  rm -f "$meta"
  git -C "$repo" worktree prune
  if [ "$delbranch" = 1 ] && [ -n "$b" ] && [ "$b" != "(detached)" ]; then
    git -C "$repo" branch -D "$b" >/dev/null 2>&1 && info "branch $b deleted"
  fi
  info "removed: $path"
}

cmd_clean() {
  local yes=0 older="" only_merged=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      --older-than) older=$2; shift 2 ;;
      --merged) only_merged=1; shift ;;
      --dry-run) yes=0; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  local base p b removable=() kept=0
  base=$(default_branch)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    b=$(branch_of "$p")
    if is_dirty "$p"; then info "KEEPING $p ($b): uncommitted changes"; kept=$((kept+1)); continue; fi
    if [ "$(unpushed_count "$p")" -gt 0 ]; then
      if [ "$only_merged" = 1 ] || ! is_merged "$p" "$base"; then
        info "KEEPING $p ($b): unpushed commits"; kept=$((kept+1)); continue
      fi
    fi
    if [ "$only_merged" = 1 ] && ! is_merged "$p" "$base"; then
      info "KEEPING $p ($b): not merged into $base"; kept=$((kept+1)); continue
    fi
    if [ -n "$older" ] && [ "$(age_days "$p")" -lt "$older" ]; then
      info "KEEPING $p ($b): newer than $older days"; kept=$((kept+1)); continue
    fi
    removable+=("$p")
  done < <(worktree_paths)

  if [ ${#removable[@]} -eq 0 ]; then
    info "nothing to clean (kept: $kept)"
    git worktree prune
    return 0
  fi
  local failed=0
  for p in "${removable[@]}"; do
    if [ "$yes" = 1 ]; then
      # Subshell: cmd_rm dies (exits) when it refuses, and one refusal must not abort
      # the sweep and leave the remaining worktrees silently unprocessed.
      ( cmd_rm "$p" ) || { failed=$((failed+1)); info "SKIPPED $p"; }
    else
      printf 'WOULD DELETE %s (%s)\n' "$p" "$(branch_of "$p")"
    fi
  done
  if [ "$yes" = 1 ]; then
    [ "$failed" -eq 0 ] || info "$failed worktree(s) skipped; see the messages above"
  else
    info "dry run: repeat with --yes to execute"
  fi
  git worktree prune
}

cmd_doctor() {
  local fix=0
  [ "${1:-}" = "--fix" ] && fix=1
  local root repo p main
  repo=$(repo_root); root=$(wt_root); main=$(main_worktree)
  printf 'repo:        %s\n' "$repo"
  printf 'wt root:     %s\n' "$root"
  git worktree prune

  local problems=0 notices=0
  # 1. worktrees outside the agreed root
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$root"/*) ;;
      *)
        problems=$((problems+1))
        if [ "$fix" = 1 ]; then
          local dest="$root/$(slugify "$(basename "$p")")"
          mkdir -p "$root"
          if is_dirty "$p"; then
            printf 'MISPLACED (dirty, not moving it): %s\n' "$p"
          elif git worktree move "$p" "$dest" 2>/dev/null; then
            printf 'MOVED: %s -> %s\n' "$p" "$dest"
          else
            printf 'MISPLACED (move failed): %s\n' "$p"
          fi
        else
          printf 'MISPLACED: %s (should live under %s)\n' "$p" "$root"
        fi
        ;;
    esac
  done < <(worktree_paths)

  # 2. orphan directories inside the root
  if [ -d "$root" ]; then
    for p in "$root"/*/; do
      [ -d "$p" ] || continue
      p=${p%/}
      case "$(basename "$p")" in .registry) continue ;; esac
      if ! git worktree list --porcelain | grep -Fxq "worktree $p"; then
        problems=$((problems+1))
        if [ "$fix" = 1 ]; then
          if [ -e "$p/.git" ]; then
            # could be a repo/worktree with work inside: never auto-delete it
            printf 'ORPHAN WITH .git (NOT deleting, check it by hand): %s\n' "$p"
          else
            strip_links "$p"
            rm -rf "$p" && printf 'ORPHAN DELETED: %s\n' "$p"
          fi
        else
          printf 'ORPHAN: %s (directory with no registered worktree)\n' "$p"
        fi
      fi
    done
  fi

  # 3. problematic names on Windows
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local bn; bn=$(basename "$p")
    if printf '%s' "$bn" | LC_ALL=C grep -Eq '[^A-Za-z0-9._-]|[ .]$' || \
       printf '%s' "$bn" | tr '[:upper:]' '[:lower:]' | grep -Eq "$RESERVED"; then
      problems=$((problems+1))
      printf 'PROBLEMATIC NAME: %s (invalid or reserved characters on Windows)\n' "$p"
    fi
    if [ ${#p} -gt 200 ]; then
      printf 'PATH TOO LONG (%s chars): %s\n' "${#p}" "$p"
    fi
    local nlinks; nlinks=$(list_links "$p" | wc -l | tr -d ' ')
    if [ "${nlinks:-0}" -gt 0 ]; then
      notices=$((notices+1))
      printf 'LINKS INSIDE (%s): %s -- removal strips them first; never delete this tree with a plain recursive delete\n' "$nlinks" "$p"
      list_links "$p" | head -3 | sed 's/^/    -> /'
    fi
  done < <(worktree_paths)

  # 4. registry entries with no worktree
  if [ -d "$(registry_dir)" ]; then
    for p in "$(registry_dir)"/*.json; do
      [ -f "$p" ] || continue
      local rp; rp=$(json_get "$p" path)
      if [ ! -d "$rp" ]; then
        problems=$((problems+1))
        if [ "$fix" = 1 ] && rm -f "$p"; then
          printf 'STALE REGISTRY ENTRY DELETED: %s\n' "$(basename "$p")"
        else
          printf 'STALE REGISTRY ENTRY: %s\n' "$(basename "$p")"
        fi
      fi
    done
  fi

  if [ "$problems" -eq 0 ]; then
    if [ "$notices" -gt 0 ]; then
      printf 'no problems, but %s notice(s) above\n' "$notices"
    else
      printf 'all clear\n'
    fi
  else
    printf '%s problem(s) found%s\n' "$problems" "$([ "$fix" = 1 ] && echo ' (fix applied where safe)' || echo '; repeat with --fix')"
  fi
}

cmd_path() {
  [ -n "${1:-}" ] || die "usage: wt path <slug>"
  local p; p=$(resolve_path "$1") || die "cannot find '$1'"
  printf '%s\n' "$p"
}

cmd_root() { printf '%s\n' "$(wt_root)"; }

cmd_help() {
  cat <<'EOF'
wt.sh - tidy, disposable git worktrees

  wt new <name> [--from <ref>] [--branch <branch>] [--task "..."] [--json]
      Creates the worktree under the agreed root with a sanitized name.
      Prints ONLY the absolute path on stdout (safe to use with cd).

  wt list [--json]        List worktrees with status (dirty/unpushed/merged/outside-root).
  wt path <slug>          Absolute path of a worktree.
  wt root                 Worktree root currently in use.
  wt rm <slug|path> [--force] [--delete-branch]
                          Remove one; refuses if there are changes or unpushed commits.
  wt clean [--merged] [--older-than <days>] [--yes]
                          Dry run (default) or delete the ones that are safe to delete.
  wt doctor [--fix]       Diagnose: misplaced, orphans, invalid names, stale registry.

Worktree root (by precedence):
  1. $AGENT_WT_ROOT/<repo-name>
  2. "root" key of <repo>/.agent/worktrees.json
  3. <repo-parent>/.worktrees/<repo-name>
EOF
}

case "${1:-help}" in
  new)    shift; cmd_new "$@" ;;
  list|ls) shift; cmd_list "$@" ;;
  rm|remove) shift; cmd_rm "$@" ;;
  clean)  shift; cmd_clean "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  path)   shift; cmd_path "$@" ;;
  root)   shift; cmd_root "$@" ;;
  version) printf '%s\n' "$VERSION" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $1 (try: wt help)" ;;
esac
