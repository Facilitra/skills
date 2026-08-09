<#
  wt.ps1 - deterministic git worktree management for agents (Windows / PowerShell 5.1+).
  Usage:  .\wt.ps1 <command> [args]    |    .\wt.ps1 help

  Why it exists: assembling worktree paths "by hand" from an agent prompt produces
  broken names (unresolved expansions, trailing newlines glued on, characters NTFS
  rejects). Here the script computes the path, not the model.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$Rest = @()
)

$ErrorActionPreference = 'Continue'   # git warns on stderr; we check $LASTEXITCODE instead
$script:Version = '1.1.1'
$script:Reserved = @('con','prn','aux','nul') + (1..9 | ForEach-Object { "com$_"; "lpt$_" })

# ---------------------------------------------------------------- helpers

# Throws rather than exits: a refusal inside a batch command (clean) must skip one
# worktree, not terminate the sweep and leave the rest silently unprocessed. The
# top-level dispatcher turns an uncaught throw back into "print to stderr, exit 1".
function Die([string]$Message) { throw $Message }
function Info([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }

function Invoke-Git {
  # Run git, return output as text; exit code lands in $script:GitExit
  param([string[]]$GitArgs)
  $output = & git @GitArgs 2>&1
  $script:GitExit = $LASTEXITCODE
  return ($output | ForEach-Object { $_.ToString() }) -join "`n"
}

function Get-GitLines {
  param([string[]]$GitArgs)
  $out = Invoke-Git $GitArgs
  if ([string]::IsNullOrWhiteSpace($out)) { return @() }
  # Split and trim: stray CRs are the classic cause of paths with junk at the end
  return $out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

function Get-RepoRoot {
  $common = Invoke-Git @('rev-parse','--path-format=absolute','--git-common-dir')
  if ($script:GitExit -ne 0) { Die 'not inside a git repository' }
  $common = $common.Trim()
  if ($common -match '[\\/]\.git$') { return (Split-Path -Parent $common) }
  $top = (Invoke-Git @('rev-parse','--path-format=absolute','--show-toplevel')).Trim()
  return $top
}

function Get-DefaultBranch {
  param([string]$Dir = '.')
  $b = (Invoke-Git @('-C',$Dir,'symbolic-ref','--quiet','--short','refs/remotes/origin/HEAD')).Trim()
  if ($script:GitExit -eq 0 -and $b) { return ($b -replace '^origin/','') }
  foreach ($cand in @('main','master','develop')) {
    Invoke-Git @('-C',$Dir,'show-ref','--verify','--quiet',"refs/heads/$cand") | Out-Null
    if ($script:GitExit -eq 0) { return $cand }
  }
  return (Invoke-Git @('-C',$Dir,'rev-parse','--abbrev-ref','HEAD')).Trim()
}

function Get-WtRoot {
  $repo = Get-RepoRoot
  $name = Split-Path -Leaf $repo
  if ($env:AGENT_WT_ROOT) {
    $root = Join-Path $env:AGENT_WT_ROOT $name
  } else {
    $cfgPath = Join-Path $repo '.agent\worktrees.json'
    $root = $null
    if (Test-Path -LiteralPath $cfgPath) {
      try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.root) {
          $root = $cfg.root
          if (-not [System.IO.Path]::IsPathRooted($root)) { $root = Join-Path $repo $root }
        }
      } catch { Info "warning: could not read $cfgPath ($($_.Exception.Message))" }
    }
    if (-not $root) { $root = Join-Path (Split-Path -Parent $repo) ".worktrees\$name" }
  }
  return ([System.IO.Path]::GetFullPath($root)).TrimEnd('\')
}

function Get-RegistryDir { return (Join-Path (Get-WtRoot) '.registry') }

function ConvertTo-Slug {
  param([string]$Text)
  $s = $Text.ToLowerInvariant()
  $s = $s -replace "[`r`n`t]", ''          # glued CR/LF/TAB: the most common failure
  $s = $s -replace '[^a-z0-9]+', '-'
  $s = $s -replace '-+', '-'
  $s = $s.Trim('-', '.', ' ')
  if ($s.Length -gt 48) { $s = $s.Substring(0, 48).TrimEnd('-') }
  if (-not $s) { Die 'the name is empty after sanitizing; use letters and digits' }
  if ($script:Reserved -contains $s) { $s = "wt-$s" }
  return $s
}

# git emits FORWARD slashes on Windows ("C:/dev/repo") while Get-WtRoot produces
# backslashes. Comparing the two raw makes every in-root test false, which reported
# correctly placed worktrees as MISPLACED and ORPHAN and broke `new`'s reuse check.
# Normalize here, once, so every caller compares like with like.
function ConvertTo-FullPath { param([string]$Path)
  try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return $Path }
}

function Get-WorktreePaths {
  # All but the main one
  $lines = Get-GitLines @('worktree','list','--porcelain')
  $paths = @()
  foreach ($l in $lines) { if ($l -like 'worktree *') { $paths += ConvertTo-FullPath $l.Substring(9).Trim() } }
  if ($paths.Count -le 1) { return @() }
  return $paths[1..($paths.Count - 1)]
}

function Get-MainWorktree {
  $lines = Get-GitLines @('worktree','list','--porcelain')
  foreach ($l in $lines) { if ($l -like 'worktree *') { return (ConvertTo-FullPath $l.Substring(9).Trim()) } }
  return $null
}

function Get-ReparsePoints {
  # Junctions, directory symlinks and file symlinks inside a tree.
  # Deliberately hand-rolled instead of Get-ChildItem -Recurse: on PowerShell 5.1
  # that cmdlet walks *through* junctions, which is both slow and how a shared
  # node_modules ends up being enumerated (and then deleted) by mistake.
  param([string]$Path)
  $found = @()
  if (-not (Test-Path -LiteralPath $Path)) { return $found }
  $stack = New-Object System.Collections.Stack
  $stack.Push($Path)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try { $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop } catch { continue }
    foreach ($i in $items) {
      if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $found += $i; continue }
      if ($i.PSIsContainer) { $stack.Push($i.FullName) }
    }
  }
  return $found
}

function Remove-Links {
  # Delete the LINKS themselves before anything recursive touches the tree.
  # [IO.Directory]::Delete($p, $false) removes the junction and leaves the target
  # alone; Remove-Item -Recurse on the same junction empties the target instead.
  # That distinction is what saves the main repo's node_modules.
  param([string]$Path)
  $links = @(Get-ReparsePoints $Path)
  $n = 0
  foreach ($l in $links) {
    try {
      if ($l.PSIsContainer) { [System.IO.Directory]::Delete($l.FullName, $false) }
      else { [System.IO.File]::Delete($l.FullName) }
      $n++
    } catch {
      # last resort: rmdir removes a junction without following it
      & cmd.exe /c rmdir """$($l.FullName)""" 2>&1 | Out-Null
      if (-not (Test-Path -LiteralPath $l.FullName)) { $n++ }
      else { Info "WARNING: could not unlink $($l.FullName) - remove it by hand before deleting the folder" }
    }
  }
  if ($n -gt 0) { Info "unlinked $n link(s) first; their targets were left untouched" }
  return $n
}

function Test-Dirty { param([string]$Path)
  $out = Invoke-Git @('-C',$Path,'status','--porcelain')
  return -not [string]::IsNullOrWhiteSpace($out)
}

function Get-BranchOf { param([string]$Path)
  $b = (Invoke-Git @('-C',$Path,'rev-parse','--abbrev-ref','HEAD')).Trim()
  if ($script:GitExit -ne 0 -or -not $b) { return '(detached)' }
  return $b
}

function Get-UnpushedCount {
  # Commits that only live here. With no remote configured we compare against the
  # base branch: otherwise everything would look "unpushed" and clean/rm would
  # never delete anything.
  param([string]$Path)
  $remotes = Get-GitLines @('-C',$Path,'remote')
  if ($remotes.Count -gt 0) {
    $n = (Invoke-Git @('-C',$Path,'rev-list','--count','HEAD','--not','--remotes')).Trim()
  } else {
    $base = Get-DefaultBranch $Path
    $n = (Invoke-Git @('-C',$Path,'rev-list','--count','HEAD','--not',$base)).Trim()
  }
  if ($script:GitExit -ne 0 -or $n -notmatch '^\d+$') { return 0 }
  return [int]$n
}

function Test-Merged {
  param([string]$Path, [string]$Base)
  $head = (Invoke-Git @('-C',$Path,'rev-parse','HEAD')).Trim()
  if ($script:GitExit -ne 0) { return $false }
  $baseSha = (Invoke-Git @('-C',$Path,'rev-parse',$Base)).Trim()
  if ($script:GitExit -ne 0) {
    $baseSha = (Invoke-Git @('-C',$Path,'rev-parse',"origin/$Base")).Trim()
    if ($script:GitExit -ne 0) { return $false }
  }
  $mb = (Invoke-Git @('-C',$Path,'merge-base',$head,$baseSha)).Trim()
  return ($script:GitExit -eq 0 -and $mb -eq $head)
}

function Get-AgeDays { param([string]$Path)
  $metaPath = Join-Path (Get-RegistryDir) ((Split-Path -Leaf $Path) + '.json')
  if (Test-Path -LiteralPath $metaPath) {
    try {
      $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
      if ($meta.created_at) { return [int]((Get-Date) - [datetime]$meta.created_at).TotalDays }
      # wt.sh-created entries may carry only the epoch field
      if ($meta.created_epoch) {
        $nowEpoch = [long]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
        return [int](($nowEpoch - [long]$meta.created_epoch) / 86400)
      }
    } catch { }
  }
  if (Test-Path -LiteralPath $Path) {
    return [int]((Get-Date) - (Get-Item -LiteralPath $Path).CreationTime).TotalDays
  }
  return 0
}

function Resolve-WorktreePath {
  param([string]$Target)
  if (Test-Path -LiteralPath $Target -PathType Container) { return (ConvertTo-FullPath $Target) }
  $candidate = Join-Path (Get-WtRoot) $Target
  if (Test-Path -LiteralPath $candidate -PathType Container) { return (ConvertTo-FullPath $candidate) }
  foreach ($p in Get-WorktreePaths) {
    if ((Split-Path -Leaf $p) -eq $Target) { return $p }
  }
  return $null
}

function Parse-Flags {
  # Returns @{ Positional = @(); Flags = @{} } for --key value / --flag style
  param([string[]]$Tokens, [string[]]$ValueFlags = @())
  $pos = @(); $flags = @{}
  for ($i = 0; $i -lt $Tokens.Count; $i++) {
    $t = $Tokens[$i]
    if ($t -like '--*' -or $t -like '-*') {
      $key = $t.TrimStart('-')
      if ($ValueFlags -contains $key) {
        $i++
        if ($i -ge $Tokens.Count) { Die "missing value for --$key" }
        $flags[$key] = $Tokens[$i]
      } else { $flags[$key] = $true }
    } else { $pos += $t }
  }
  return @{ Positional = $pos; Flags = $flags }
}

# ---------------------------------------------------------------- commands

function Cmd-New {
  param([string[]]$Tokens)
  $p = Parse-Flags $Tokens @('from','branch','task')
  if ($p.Positional.Count -lt 1) { Die 'usage: wt new <name> [--from <ref>] [--branch <branch>] [--task "..."]' }

  $repo = Get-RepoRoot
  $root = Get-WtRoot
  $slug = ConvertTo-Slug $p.Positional[0]
  $path = Join-Path $root $slug
  $branch = if ($p.Flags.branch) { $p.Flags.branch } else { "agent/$slug" }
  $base = if ($p.Flags.from) { $p.Flags.from } else { (Invoke-Git @('-C',$repo,'rev-parse','--abbrev-ref','HEAD')).Trim() }

  if (Test-Path -LiteralPath $path) {
    if ((Get-WorktreePaths) -contains $path) {
      Info "a worktree already exists at $path (reusing it)"
      Write-Output $path; return
    }
    Die "$path exists but is not a registered worktree; delete it or pick another name"
  }

  New-Item -ItemType Directory -Force -Path $root | Out-Null

  Invoke-Git @('-C',$repo,'show-ref','--verify','--quiet',"refs/heads/$branch") | Out-Null
  if ($script:GitExit -eq 0) {
    $out = Invoke-Git @('-C',$repo,'worktree','add',$path,$branch)
  } else {
    $out = Invoke-Git @('-C',$repo,'worktree','add','-b',$branch,$path,$base)
  }
  if ($script:GitExit -ne 0) { Die "git worktree add failed: $out" }

  New-Item -ItemType Directory -Force -Path (Get-RegistryDir) | Out-Null
  $meta = [ordered]@{
    slug = $slug; path = $path; branch = $branch; base = $base
    task = [string]$p.Flags.task; repo = $repo
    # Both fields, because wt.sh reads created_epoch and this script reads created_at.
    # Writing only one makes --older-than fall back to filesystem timestamps when the
    # two scripts are mixed on the same repo, and those reset on copy.
    # [long] straight off the TimeSpan: going via a string would be parsed with the
    # current culture, and a comma-decimal locale turns 1786301985.01 into 178630198501.
    created_epoch = [string][long]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
    created_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  ($meta | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path (Get-RegistryDir) "$slug.json") -Encoding UTF8

  if ($p.Flags.json) {
    ([ordered]@{ path = $path; branch = $branch; slug = $slug } | ConvertTo-Json -Compress) | Write-Output
  } else {
    Write-Output $path
  }
}

function Get-WorktreeStatus {
  $root = Get-WtRoot
  $base = Get-DefaultBranch (Get-MainWorktree)
  $rows = @()
  foreach ($p in Get-WorktreePaths) {
    $rows += [pscustomobject]@{
      path     = $p
      branch   = Get-BranchOf $p
      dirty    = Test-Dirty $p
      unpushed = Get-UnpushedCount $p
      merged   = Test-Merged $p $base
      in_root  = $p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
      age_days = Get-AgeDays $p
    }
  }
  return $rows
}

function Cmd-List {
  param([string[]]$Tokens)
  $rows = @(Get-WorktreeStatus)
  if ($Tokens -contains '--json') {
    if ($rows.Count -eq 0) { Write-Output '[]' }
    else { ($rows | ConvertTo-Json -Depth 4 -Compress) | Write-Output }
    return
  }
  if ($rows.Count -eq 0) { Info 'no worktrees'; return }
  foreach ($r in $rows) {
    $flags = @()
    if ($r.dirty) { $flags += 'dirty' }
    if ($r.unpushed -gt 0) { $flags += "unpushed=$($r.unpushed)" }
    if ($r.merged) { $flags += 'merged' }
    if (-not $r.in_root) { $flags += 'OUTSIDE-ROOT' }
    $suffix = if ($flags.Count) { "  [$($flags -join ' ')]" } else { '' }
    Write-Output ("{0,-55} {1,-28}{2}" -f $r.path, $r.branch, $suffix)
  }
}

function Cmd-Remove {
  param([string[]]$Tokens)
  $p = Parse-Flags $Tokens
  if ($p.Positional.Count -lt 1) { Die 'usage: wt rm <slug|path> [--force] [--delete-branch]' }
  $path = Resolve-WorktreePath $p.Positional[0]
  if (-not $path) { Die "cannot find worktree '$($p.Positional[0])' (try: wt list)" }
  $branch = Get-BranchOf $path
  $force = [bool]$p.Flags.force

  if (-not $force) {
    if (Test-Dirty $path) { Die "'$path' has uncommitted changes. Review them with: git -C `"$path`" status. Use --force to discard them." }
    $un = Get-UnpushedCount $path
    if ($un -gt 0) { Die "'$path' has $un unpushed commit(s) on '$branch'. Push the branch or use --force." }
  }

  Remove-Links $path | Out-Null
  # Every git call runs against the main repo: the skill tells you to Set-Location into
  # the worktree to work, and `git worktree remove` fails when run from inside its target.
  $repo = Get-RepoRoot

  # Windows locks a directory that is some process's working directory, so removing the
  # worktree you are standing in fails with "Permission denied" no matter which repo git
  # is pointed at. Step out first. POSIX shells do not need this; Windows does.
  $here = (Get-Location).ProviderPath.TrimEnd('\')
  if ($here -eq $path -or $here.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Set-Location $repo
    [Environment]::CurrentDirectory = $repo
    Info "moved out of $path (it is being removed); you are now in $repo"
  }
  # Resolved BEFORE the removal: Get-RegistryDir walks up through Get-RepoRoot, and if
  # the caller is standing inside the worktree being deleted, cwd no longer exists by
  # then, so the lookup fails and the entry survives as a phantom.
  $meta = Join-Path (Get-RegistryDir) ((Split-Path -Leaf $path) + '.json')
  $gitArgs = @('-C',$repo,'worktree','remove')
  if ($force) { $gitArgs += '--force' }
  $gitArgs += $path
  $out = Invoke-Git $gitArgs
  if ($script:GitExit -ne 0) { Die "could not remove ${path}: $out" }

  if (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force }
  Invoke-Git @('-C',$repo,'worktree','prune') | Out-Null

  if ($p.Flags.'delete-branch' -and $branch -ne '(detached)') {
    Invoke-Git @('-C',$repo,'branch','-D',$branch) | Out-Null
    if ($script:GitExit -eq 0) { Info "branch $branch deleted" }
  }
  Info "removed: $path"
}

function Cmd-Clean {
  param([string[]]$Tokens)
  $p = Parse-Flags $Tokens @('older-than')
  $yes = [bool]($p.Flags.yes -or $p.Flags.y)
  $onlyMerged = [bool]$p.Flags.merged
  $older = if ($p.Flags.'older-than') { [int]$p.Flags.'older-than' } else { -1 }

  $removable = @(); $kept = 0
  foreach ($r in @(Get-WorktreeStatus)) {
    if ($r.dirty)     { Info "KEEPING $($r.path) ($($r.branch)): uncommitted changes"; $kept++; continue }
    if ($r.unpushed -gt 0 -and (-not $r.merged -or $onlyMerged)) {
      Info "KEEPING $($r.path) ($($r.branch)): unpushed commits"; $kept++; continue
    }
    if ($onlyMerged -and -not $r.merged) { Info "KEEPING $($r.path) ($($r.branch)): not merged"; $kept++; continue }
    if ($older -ge 0 -and $r.age_days -lt $older) { Info "KEEPING $($r.path): newer than $older days"; $kept++; continue }
    $removable += $r.path
  }

  if ($removable.Count -eq 0) { Info "nothing to clean (kept: $kept)"; Invoke-Git @('worktree','prune') | Out-Null; return }
  $failed = 0
  foreach ($path in $removable) {
    if ($yes) {
      # One refusal must not abort the sweep and leave the rest silently untouched.
      try { Cmd-Remove @($path) } catch { $failed++; Info "SKIPPED ${path}: $($_.Exception.Message)" }
    }
    else { Write-Output "WOULD DELETE $path" }
  }
  if (-not $yes) { Info 'dry run: repeat with --yes to execute' }
  elseif ($failed -gt 0) { Info "$failed worktree(s) skipped; see the messages above" }
  Invoke-Git @('worktree','prune') | Out-Null
}

function Cmd-Doctor {
  param([string[]]$Tokens)
  $fix = ($Tokens -contains '--fix')
  $repo = Get-RepoRoot
  $root = Get-WtRoot
  Write-Output "repo:        $repo"
  Write-Output "wt root:     $root"
  Invoke-Git @('worktree','prune') | Out-Null
  $problems = 0; $notices = 0

  foreach ($p in Get-WorktreePaths) {
    # 1. misplaced
    if (-not $p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
      $problems++
      if ($fix) {
        $dest = Join-Path $root (ConvertTo-Slug (Split-Path -Leaf $p))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        if (Test-Dirty $p) {
          Write-Output "MISPLACED (dirty, not moving it): $p"
        } else {
          Invoke-Git @('worktree','move',$p,$dest) | Out-Null
          if ($script:GitExit -eq 0) { Write-Output "MOVED: $p -> $dest" }
          else { Write-Output "MISPLACED (move failed): $p" }
        }
      } else { Write-Output "MISPLACED: $p (should live under $root)" }
    }
    # 3. problematic names on Windows
    $leaf = Split-Path -Leaf $p
    if ($leaf -match '[^A-Za-z0-9._-]' -or $leaf -match '[ .]$' -or ($script:Reserved -contains $leaf.ToLowerInvariant())) {
      $problems++
      Write-Output "PROBLEMATIC NAME: $p (invalid or reserved characters on Windows)"
    }
    if ($p.Length -gt 200) { Write-Output "PATH TOO LONG ($($p.Length) chars): $p  -> enable long paths or shorten the root" }
    $links = @(Get-ReparsePoints $p)
    if ($links.Count -gt 0) {
      $notices++
      Write-Output "LINKS INSIDE ($($links.Count)): $p  -- removal strips them first; never delete this tree with Remove-Item -Recurse"
      foreach ($l in ($links | Select-Object -First 3)) { Write-Output "    -> $($l.FullName)" }
    }
  }

  # 2. orphans inside the root
  if (Test-Path -LiteralPath $root) {
    $live = @(Get-WorktreePaths)
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
      if ($d.Name -eq '.registry') { continue }
      if ($live -notcontains $d.FullName) {
        $problems++
        if ($fix) {
          if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) {
            Write-Output "ORPHAN WITH .git (NOT deleting, check it by hand): $($d.FullName)"
          } else {
            Remove-Links $d.FullName | Out-Null
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
            Write-Output "ORPHAN DELETED: $($d.FullName)"
          }
        } else { Write-Output "ORPHAN: $($d.FullName) (directory with no registered worktree)" }
      }
    }
  }

  # 4. stale registry
  if (Test-Path -LiteralPath (Get-RegistryDir)) {
    foreach ($f in Get-ChildItem -LiteralPath (Get-RegistryDir) -Filter *.json -ErrorAction SilentlyContinue) {
      try {
        $meta = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $meta.path)) {
          $problems++
          if ($fix) { Remove-Item -LiteralPath $f.FullName -Force; Write-Output "STALE REGISTRY ENTRY DELETED: $($f.Name)" }
          else { Write-Output "STALE REGISTRY ENTRY: $($f.Name)" }
        }
      } catch { }
    }
  }

  if ($problems -eq 0 -and $notices -gt 0) { Write-Output "no problems, but $notices notice(s) above" }
  elseif ($problems -eq 0) { Write-Output 'all clear' }
  elseif ($fix) { Write-Output "$problems problem(s) found (fix applied where safe)" }
  else { Write-Output "$problems problem(s) found; repeat with --fix" }
}

function Cmd-Help {
  @'
wt.ps1 - tidy, disposable git worktrees

  wt new <name> [--from <ref>] [--branch <branch>] [--task "..."] [--json]
      Creates the worktree under the agreed root with a sanitized name.
      Prints ONLY the absolute path (safe to use with Set-Location).

  wt list [--json]        List worktrees with status (dirty/unpushed/merged/outside-root).
  wt path <slug>          Absolute path of a worktree.
  wt root                 Worktree root currently in use.
  wt rm <slug|path> [--force] [--delete-branch]
                          Remove one; refuses if there are changes or unpushed commits.
  wt clean [--merged] [--older-than <days>] [--yes]
                          Dry run (default) or delete the ones that are safe to delete.
  wt doctor [--fix]       Diagnose: misplaced, orphans, invalid names, stale registry.

Worktree root (by precedence):
  1. $env:AGENT_WT_ROOT\<repo-name>
  2. "root" key of <repo>\.agent\worktrees.json
  3. <repo-parent>\.worktrees\<repo-name>
'@ | Write-Output
}

try {
  switch ($Command.ToLowerInvariant()) {
    'new'     { Cmd-New $Rest }
    'list'    { Cmd-List $Rest }
    'ls'      { Cmd-List $Rest }
    'rm'      { Cmd-Remove $Rest }
    'remove'  { Cmd-Remove $Rest }
    'clean'   { Cmd-Clean $Rest }
    'doctor'  { Cmd-Doctor $Rest }
    'path'    { $r = Resolve-WorktreePath $Rest[0]; if (-not $r) { Die "cannot find '$($Rest[0])'" }; Write-Output $r }
    'root'    { Write-Output (Get-WtRoot) }
    'version' { Write-Output $script:Version }
    default   { Cmd-Help }
  }
} catch {
  # Die throws so batch commands can catch it; anything reaching here is fatal.
  [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
  exit 1
}
