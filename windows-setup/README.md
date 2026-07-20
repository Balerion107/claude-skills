# windows-setup — Claude Code environment toolkit for Windows 11

Maintainer environment tooling (like `audit/`, this folder is committed but
**excluded from the repo's headline skill counters** — see
`scripts/derive_counters.py`). It bootstraps and repairs a complete Claude Code
setup on a Windows 11 machine: Git/Git LFS/Git Bash wiring, dependencies,
Agent SDK, global `~/.claude` structure, working example agent + skill, and a
Model Council starter.

Target machine: Windows 11 Pro 25H2, AMD Ryzen AI 9 HX 375. Everything is
User-scope — **no admin required** — and PowerShell 5.1 + 7 compatible.

## Run order

Open PowerShell in this folder (clone the repo or copy the folder over), then:

```powershell
# 0. If scripts are blocked: allow local scripts for this user once
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 1. Diagnose the git mess first (read-only, writes a markdown report)
.\Fix-GitForWindows-ClaudeCode.ps1

# 2. Read the GitFixer_Report_*.md it produced, then apply the fix
.\Fix-GitForWindows-ClaudeCode.ps1 -Apply
#    add -CleanUserPath to also strip duplicate Git entries from the User PATH

# 3. Install/configure everything else (Git, Node, Python, Claude Code,
#    Agent SDK, ~/.claude structure). Preview first if you like:
.\Install-ClaudeCodeEnvironment.ps1 -DryRun
.\Install-ClaudeCodeEnvironment.ps1

# 4. IMPORTANT: close and reopen ALL terminals + Claude Code
#    (environment-variable changes only reach new processes)

# 5. Re-check the whole chain any time
.\Verify-ClaudeCodeSetup.ps1

# 6. In each project root, create the .claude structure + example agent/skill
.\Setup-ClaudeFolders.ps1 -BasePath C:\Projects\my-app
```

## What each script does

| Script | Purpose |
|---|---|
| `Fix-GitForWindows-ClaudeCode.ps1` | Finds every Git install (known roots, registry, `where.exe`, PATH — no slow full-drive crawl; `-DeepScan` for a depth-limited sweep). Picks and *validates* the best `bin\bash.exe`, writes a report, and with `-Apply` sets `CLAUDE_CODE_GIT_BASH_PATH`, optionally cleans the User PATH, refreshes LFS hooks **with the chosen git.exe**, and sets `core.longpaths=true`. Backs up PATH/env/gitconfigs first; never deletes an install. |
| `Install-ClaudeCodeEnvironment.ps1` | Idempotent installer: Git(+LFS), Node LTS, Python 3.12 (real one, not the Store stub), Claude Code (native installer → npm fallback), `pip install claude-agent-sdk anthropic`, git-bash env var, `~/.claude` global memory/agents/skills/settings. `-GrantBroadFileAccess` below. |
| `Verify-ClaudeCodeSetup.ps1` | Read-only health check of the whole chain; exit code = failure count. |
| `Setup-ClaudeFolders.ps1` | Per-project `.claude/` bootstrap: settings, memory/lessons, a **working `code-reviewer` subagent**, a **working `git-troubleshooter` skill**, project `CLAUDE.md`. Never overwrites existing files. |
| `model-council/model_council.py` | Working Model Council starter: rule-based router, live Anthropic calls when `ANTHROPIC_API_KEY` is set (`pip install anthropic`), deterministic free simulation otherwise, parallel fan-out, judge fusion, `--json`. |
| `model-council/MODEL-COUNCIL-PLAN.md` | Phased plan from the starter to a production council (cost ledger → Haiku router → Claude Code `/council` command → fusion strategies → optional local NPU lane → Agent SDK executor). |

## Giving Claude "global" access to your files

Claude Code always works from the directory you launch it in. Three ways to
widen that, from safest to broadest:

1. **Per session:** `claude --add-dir C:\OtherProject` (or `/add-dir` inside a
   session).
2. **Per project:** add paths to `permissions.additionalDirectories` in the
   project's `.claude/settings.json`.
3. **Everywhere:** `Install-ClaudeCodeEnvironment.ps1 -GrantBroadFileAccess`
   puts your profile folder (or `-AccessPaths C:\Projects,...`) into
   `~/.claude/settings.json` → `permissions.additionalDirectories`.

True "all files on the machine" access is deliberately not a thing to want:
every session could then touch everything, and OS-protected paths still block
it. Granting your user profile (option 3) is the practical maximum; granting
named project roots is the smart default. You can always start Claude Code in
`C:\` for a one-off whole-disk task — permission prompts still apply.

## Troubleshooting quick table

| Symptom | Fix |
|---|---|
| "Claude Code on Windows requires git-bash" / `spawn bash ENOENT` | `Fix-GitForWindows-ClaudeCode.ps1 -Apply`, then restart terminals. The env var must point at `<GitRoot>\bin\bash.exe`. |
| `bash` opens WSL/Ubuntu | Harmless once the env var is set — Claude Code uses the explicit path, not PATH lookup. |
| LFS files arrive as small text "pointer" files | `git lfs install --skip-repo` with the right git (the fixer does this), then `git lfs pull` in the repo. |
| `Filename too long` on checkout | `git config --global core.longpaths true` (installer + fixer both set it). |
| `winget` not found | Install "App Installer" from the Microsoft Store. |
| `python` opens the Microsoft Store | The Store stub is shadowing real Python — the installer detects and replaces it; or disable it under Settings → Apps → Advanced app settings → App execution aliases. |
| Tool installed but "not recognized" | New PATH entries need a **new** terminal. Close everything, reopen. |
| Env var changes don't stick in Claude Code | Claude Code inherits env from its parent. Restart the terminal *and* Claude Code (or VS Code entirely if using the extension). |

## Cowork / team note

Claude Cowork lives in the Claude desktop app (claude.ai side), not in this
repo: sign in → Cowork/Projects area → create a workspace and share it. What
*is* shareable from here: this repo itself is your skill library — teammates
clone it and point Claude Code at the same skills/agents, which is the
practical "shared brain" until you wire Cowork.

## Design notes

- The old draft scripts this folder replaces had real bugs, fixed here:
  `"$env:ProgramFiles (x86)"` mis-interpolation, a triple full-drive recursive
  scan (hours on a big disk), no validation that the chosen bash actually runs,
  LFS re-init against whatever `git` PATH resolved to (often the wrong
  install), `Stop-Transcript` skipped when the script errored, and UTF-8-BOM
  writes that can break YAML-frontmatter/JSON parsers.
- `model_council.py` intentionally keeps a zero-spend `--simulate` mode as its
  permanent test harness (same philosophy as `engineering/skillopt-sleep`'s
  `mock` backend). It lives in this excluded folder because repo skills'
  `scripts/` must stay LLM-call-free per root `CLAUDE.md`.
