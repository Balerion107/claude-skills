<#
.SYNOPSIS
    Bootstrap the standard Claude Code project structure (.claude/ with skills,
    memory, agents, commands, templates + starter files) in a project directory.

.DESCRIPTION
    Idempotent: never overwrites anything that already exists. Creates:

      .claude/
        settings.json          starter permissions (only if absent)
        agents/code-reviewer.md    working example subagent
        skills/git-troubleshooter/SKILL.md   working example skill
        memory/lessons.md      lessons log referenced by CLAUDE.md
        commands/              project slash commands (empty, ready)
        templates/             prompt/template stash
      CLAUDE.md                project memory (only if absent)
      plans/  scripts/  docs/

.PARAMETER BasePath
    Project root to set up. Default: current directory.

.EXAMPLE
    .\Setup-ClaudeFolders.ps1                 # current directory
    .\Setup-ClaudeFolders.ps1 -BasePath C:\Projects\my-app
#>

[CmdletBinding()]
param(
    [string]$BasePath = "."
)

$BasePath = (Resolve-Path -LiteralPath $BasePath).Path

$folders = @(
    ".claude",
    ".claude\skills",
    ".claude\memory",
    ".claude\agents",
    ".claude\commands",
    ".claude\templates",
    "plans",
    "scripts",
    "docs"
)

foreach ($folder in $folders) {
    $full = Join-Path $BasePath $folder
    if (-not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Write-Host "Created: $full" -ForegroundColor Green
    } else {
        Write-Host "Exists:  $full" -ForegroundColor Gray
    }
}

function Write-IfMissing {
    param([string]$Path, [string]$Content, [string]$Label)
    if (Test-Path -LiteralPath $Path) {
        Write-Host "Exists:  $Label" -ForegroundColor Gray
        return
    }
    # ASCII avoids the UTF8 BOM that Windows PowerShell 5.1 emits - a BOM in
    # front of YAML frontmatter or JSON breaks some parsers.
    $Content | Out-File -FilePath $Path -Encoding ASCII
    Write-Host "Created: $Label" -ForegroundColor Green
}

# --- Project CLAUDE.md -------------------------------------------------------
$projectMd = @'
# CLAUDE.md

Project memory for Claude Code. Keep this short and current.

## What this project is
- (one paragraph: what it does, who it is for)

## Commands
- Build: (fill in)
- Test:  (fill in)
- Run:   (fill in)

## Conventions
- (naming, formatting, review rules that Claude must follow here)

## Self-learning
When corrected, add the lesson as a one-line rule under ## Lessons in
.claude/memory/lessons.md before continuing.
'@
Write-IfMissing -Path (Join-Path $BasePath 'CLAUDE.md') -Content $projectMd -Label 'CLAUDE.md'

# --- Lessons / memory --------------------------------------------------------
$lessonsMd = @'
# Lessons & Memory

One lesson per entry. Newest on top. Start each with a one-line summary.

## Example
**Title:** Git Bash path fix for Claude Code on Windows
**Date:** 2026-07-19
**Summary:** Set CLAUDE_CODE_GIT_BASH_PATH user env var to Git\bin\bash.exe
after cleaning up multiple Git installs (see windows-setup/ toolkit).
'@
Write-IfMissing -Path (Join-Path $BasePath '.claude\memory\lessons.md') -Content $lessonsMd -Label '.claude/memory/lessons.md'

# --- Starter settings.json ---------------------------------------------------
$settingsJson = @'
{
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)"
    ]
  }
}
'@
Write-IfMissing -Path (Join-Path $BasePath '.claude\settings.json') -Content $settingsJson -Label '.claude/settings.json'

# --- Example subagent (works as-is) -----------------------------------------
$reviewerAgent = @'
---
name: code-reviewer
description: Reviews recently changed code for correctness, clarity, and project-convention adherence. Use proactively after writing or modifying a significant chunk of code.
tools: Read, Grep, Glob, Bash
---

You are a pragmatic senior code reviewer for this repository.

When invoked:
1. Run `git diff` (or `git diff --staged`) to see what changed.
2. Read the changed files fully - never review from the diff alone.
3. Check: correctness on real inputs, error handling, naming, duplication,
   and whether project conventions in CLAUDE.md are followed.

Report findings ranked by severity (blocker / major / minor / nit), each with
file:line and a concrete suggested fix. If nothing is wrong, say so plainly.
Do not rewrite code yourself - report only.
'@
Write-IfMissing -Path (Join-Path $BasePath '.claude\agents\code-reviewer.md') -Content $reviewerAgent -Label '.claude/agents/code-reviewer.md'

# --- Example skill (works as-is) --------------------------------------------
$skillDir = Join-Path $BasePath '.claude\skills\git-troubleshooter'
if (-not (Test-Path -LiteralPath $skillDir)) { New-Item -ItemType Directory -Path $skillDir -Force | Out-Null }
$gitSkill = @'
---
name: git-troubleshooter
description: Diagnose and repair Git problems on this Windows machine - broken Git Bash wiring, LFS smudge errors, multiple Git installs, PATH conflicts, longpath checkout failures. Use when git commands fail, Claude Code reports a git-bash/shell error, or clones behave strangely.
---

# Git Troubleshooter (Windows)

## First moves, in order
1. `git --version` and `where.exe git.exe` - more than one hit means scattered
   installs; prefer C:\Program Files\Git.
2. Check the env var: `[Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH','User')`
   - it must point at `<GitRoot>\bin\bash.exe` and the file must exist.
3. For deep diagnosis or repair, run the toolkit script (diagnose first, then
   apply): `windows-setup/Fix-GitForWindows-ClaudeCode.ps1` from the
   claude-skills repo, then `-Apply` after reviewing its report.

## Known failure signatures
- "Claude Code requires git-bash" / spawn bash ENOENT -> env var missing or
  pointing at a deleted install. Re-run the fixer with -Apply.
- `bash` opens WSL instead of Git Bash -> harmless once the env var is set;
  Claude Code uses the explicit path, not PATH resolution.
- LFS files come down as text pointers -> `git lfs install --skip-repo` with
  the RIGHT git.exe, then `git lfs pull` in the repo.
- "Filename too long" on checkout -> `git config --global core.longpaths true`.

## Rules
- Never delete a Git installation from a script; uninstall via Settings > Apps.
- After any env-var change, fully restart terminals and Claude Code.
'@
Write-IfMissing -Path (Join-Path $skillDir 'SKILL.md') -Content $gitSkill -Label '.claude/skills/git-troubleshooter/SKILL.md'

Write-Host ""
Write-Host "Claude project structure ready in $BasePath" -ForegroundColor Cyan
Write-Host "Edit CLAUDE.md with real project facts - that file is the highest-leverage one." -ForegroundColor Cyan
