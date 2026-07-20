<#
.SYNOPSIS
    One-shot installer + configurator for a complete Claude Code environment on
    Windows 11: Git (+LFS), Node LTS, Python, Claude Code CLI, Claude Agent SDK,
    git-bash wiring, global ~/.claude structure, and optional broad file access.

.DESCRIPTION
    Idempotent - safe to rerun; every step checks before it installs or writes.
    Installs via winget (user scope where possible; no admin needed for most
    steps). Configures:

      - Git for Windows (bundles Git Bash + Git LFS + Credential Manager)
      - git lfs install (global hooks) + core.longpaths=true
      - CLAUDE_CODE_GIT_BASH_PATH user env var (the #1 Claude Code Windows fix)
      - Node.js LTS (npm - needed for MCP servers and the npm install fallback)
      - Python 3.12 (real interpreter, not the Microsoft Store stub)
      - Claude Code CLI (native installer, npm fallback)
      - Claude Agent SDK for Python (pip install claude-agent-sdk) + anthropic SDK
      - ~/.claude global structure: CLAUDE.md memory file, agents/, commands/,
        skills/ folders, and a starter settings.json (never overwrites yours -
        writes settings.suggested.json instead if one exists)
      - Optional: -GrantBroadFileAccess adds directories to
        permissions.additionalDirectories in ~/.claude/settings.json so Claude
        Code can work across them without per-session --add-dir flags.

.PARAMETER DryRun
    Print every action without executing anything.

.PARAMETER Yes
    Skip the single up-front confirmation prompt (for scripted runs).

.PARAMETER GrantBroadFileAccess
    Add -AccessPaths (default: your user profile folder) to Claude Code's
    additionalDirectories. SECURITY NOTE: this lets any Claude Code session
    read/edit files in those trees, subject to your permission mode. Granting
    your whole profile is convenient but broad - prefer listing specific
    project roots if you can.

.PARAMETER AccessPaths
    Directories to grant when -GrantBroadFileAccess is set.
    Default: $env:USERPROFILE.

.PARAMETER SkipNode / SkipPython / SkipAgentSdk / SkipClaudeCode
    Skip individual components.

.EXAMPLE
    .\Install-ClaudeCodeEnvironment.ps1 -DryRun     # preview
    .\Install-ClaudeCodeEnvironment.ps1             # install everything
    .\Install-ClaudeCodeEnvironment.ps1 -GrantBroadFileAccess -AccessPaths 'C:\Projects','C:\Users\me\Documents'

.NOTES
    Windows PowerShell 5.1 and PowerShell 7+ compatible. After it finishes,
    close and reopen all terminals (env-var changes need new processes).
    Run Fix-GitForWindows-ClaudeCode.ps1 first if you have known-messy
    scattered Git installs - it diagnoses; this script installs.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$GrantBroadFileAccess,
    [string[]]$AccessPaths = @($env:USERPROFILE),
    [switch]$SkipNode,
    [switch]$SkipPython,
    [switch]$SkipAgentSdk,
    [switch]$SkipClaudeCode
)

$ErrorActionPreference = 'Continue'

function Write-Section { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2   { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Bad     { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info    { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { Write-Host "  [DRYRUN] $Description" -ForegroundColor Magenta; return $true }
    Write-Info $Description
    try { & $Action; return $true } catch { Write-Bad "$Description -- $($_.Exception.Message)"; return $false }
}

function Test-Cmd {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function Update-SessionPath {
    # Re-read Machine + User PATH so tools installed moments ago resolve now.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = "$machine;$user"
    # Native Claude Code installer target + npm global dir, if not on PATH yet:
    foreach ($extra in @((Join-Path $env:USERPROFILE '.local\bin'), (Join-Path $env:APPDATA 'npm'))) {
        if ((Test-Path -LiteralPath $extra) -and ($env:PATH -notlike "*$extra*")) { $env:PATH = "$env:PATH;$extra" }
    }
}

function Install-WingetPackage {
    param([string]$Id, [string]$Display)
    if (-not (Test-Cmd 'winget')) {
        Write-Bad "winget not found. Install 'App Installer' from the Microsoft Store, then rerun."
        return $false
    }
    return (Invoke-Step "winget install $Display ($Id)" {
        winget install --id $Id -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            # -1978335189 = APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
            throw "winget exited with code $LASTEXITCODE"
        }
    })
}

Write-Host "=== Claude Code Environment Installer (Windows) ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "Mode: DRY RUN - nothing will be installed or written" -ForegroundColor Magenta }

if (-not $DryRun -and -not $Yes) {
    Write-Host ""
    Write-Host "This will install/configure: Git(+LFS), Node LTS, Python 3.12, Claude Code,"
    Write-Host "Claude Agent SDK, git-bash env var, and the ~/.claude global structure."
    $answer = Read-Host "Continue? [y/N]"
    if ($answer -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
}

$failures = 0

# ============================================================
# 1. Git for Windows (+ LFS + Bash)
# ============================================================
Write-Section "1/8 Git for Windows"
Update-SessionPath
if (Test-Cmd 'git') {
    Write-Ok ("Already installed: " + (git --version 2>&1 | Select-Object -First 1))
} else {
    if (-not (Install-WingetPackage -Id 'Git.Git' -Display 'Git for Windows')) { $failures++ }
    Update-SessionPath
}

if (-not $DryRun -and (Test-Cmd 'git')) {
    $lfs = git lfs version 2>&1 | Select-Object -First 1
    if ("$lfs" -match 'git-lfs') {
        Write-Ok "Git LFS present: $lfs"
    } else {
        if (-not (Install-WingetPackage -Id 'GitHub.GitLFS' -Display 'Git LFS')) { $failures++ }
        Update-SessionPath
    }
    Invoke-Step "git lfs install (global hooks)" { git lfs install --skip-repo | Out-Null } | Out-Null
    Invoke-Step "git config --global core.longpaths true" { git config --global core.longpaths true } | Out-Null

    # Identity - only prompt if missing and interactive.
    $uname = git config --global user.name 2>$null
    if ([string]::IsNullOrWhiteSpace("$uname") -and -not $Yes) {
        $n = Read-Host "git user.name is not set. Enter a name (or press Enter to skip)"
        if (-not [string]::IsNullOrWhiteSpace($n)) { git config --global user.name "$n" }
        $e = Read-Host "git user.email (or Enter to skip)"
        if (-not [string]::IsNullOrWhiteSpace($e)) { git config --global user.email "$e" }
    }
}

# ============================================================
# 2. CLAUDE_CODE_GIT_BASH_PATH
# ============================================================
Write-Section "2/8 Git Bash wiring for Claude Code"
$bashPath = $null
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -ne $gitCmd) {
    # ...\Git\cmd\git.exe -> ...\Git\bin\bash.exe
    $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCmd.Source)
    $probe = Join-Path $gitRoot 'bin\bash.exe'
    if (Test-Path -LiteralPath $probe) { $bashPath = $probe }
}
if ($null -eq $bashPath) {
    $probe = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (Test-Path -LiteralPath $probe) { $bashPath = $probe }
}
if ($null -ne $bashPath) {
    $existing = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
    if ($existing -eq $bashPath) {
        Write-Ok "CLAUDE_CODE_GIT_BASH_PATH already set: $bashPath"
    } else {
        Invoke-Step "Set CLAUDE_CODE_GIT_BASH_PATH = $bashPath (User)" {
            [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bashPath, 'User')
            $env:CLAUDE_CODE_GIT_BASH_PATH = $bashPath
        } | Out-Null
    }
} else {
    Write-Warn2 "Could not locate bin\bash.exe - run Fix-GitForWindows-ClaudeCode.ps1 for deep diagnosis."
    $failures++
}

# ============================================================
# 3. Node.js LTS
# ============================================================
Write-Section "3/8 Node.js LTS"
if ($SkipNode) { Write-Info "Skipped (-SkipNode)." }
elseif (Test-Cmd 'node') { Write-Ok ("Already installed: node " + (node --version 2>&1)) }
else {
    if (-not (Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Display 'Node.js LTS')) { $failures++ }
    Update-SessionPath
}

# ============================================================
# 4. Python 3.12 (real interpreter, not the Store stub)
# ============================================================
Write-Section "4/8 Python"
if ($SkipPython) { Write-Info "Skipped (-SkipPython)." }
else {
    $pythonOk = $false
    $pyCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $pyCmd -and $pyCmd.Source -notmatch '(?i)WindowsApps') {
        $v = python --version 2>&1
        if ("$v" -match '^Python 3') { $pythonOk = $true; Write-Ok "Already installed: $v" }
    }
    if (-not $pythonOk) {
        # The WindowsApps python.exe is a 0-byte Store redirect stub, not Python.
        if (-not (Install-WingetPackage -Id 'Python.Python.3.12' -Display 'Python 3.12')) { $failures++ }
        Update-SessionPath
    }
}

# ============================================================
# 5. Claude Code CLI
# ============================================================
Write-Section "5/8 Claude Code CLI"
if ($SkipClaudeCode) { Write-Info "Skipped (-SkipClaudeCode)." }
else {
    Update-SessionPath
    if (Test-Cmd 'claude') {
        Write-Ok ("Already installed: " + (claude --version 2>&1 | Select-Object -First 1))
    } else {
        $native = Invoke-Step "Native installer: irm https://claude.ai/install.ps1 | iex" {
            Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
        }
        Update-SessionPath
        if (-not $DryRun -and -not (Test-Cmd 'claude')) {
            if (Test-Cmd 'npm') {
                Write-Warn2 "Native installer did not land; falling back to npm."
                if (-not (Invoke-Step "npm install -g @anthropic-ai/claude-code" {
                    npm install -g '@anthropic-ai/claude-code' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "npm exited $LASTEXITCODE" }
                })) { $failures++ }
                Update-SessionPath
            } elseif (-not $native) {
                Write-Bad "Claude Code install failed and npm is unavailable for fallback."
                $failures++
            }
        }
    }
}

# ============================================================
# 6. Claude Agent SDK (Python) + Anthropic SDK
# ============================================================
Write-Section "6/8 Claude Agent SDK"
if ($SkipAgentSdk) { Write-Info "Skipped (-SkipAgentSdk)." }
elseif (-not (Test-Cmd 'python') -and -not $DryRun) {
    Write-Warn2 "Python unavailable - skipping SDK install. Reopen a terminal and rerun after Python installs."
    $failures++
} else {
    if (-not (Invoke-Step "python -m pip install --upgrade claude-agent-sdk anthropic" {
        python -m pip install --upgrade --quiet claude-agent-sdk anthropic
        if ($LASTEXITCODE -ne 0) { throw "pip exited $LASTEXITCODE" }
    })) { $failures++ }
    Write-Info "TypeScript SDK is per-project: npm install @anthropic-ai/claude-agent-sdk"
}

# ============================================================
# 7. Global ~/.claude structure (memory, agents, skills, settings)
# ============================================================
Write-Section "7/8 Global ~/.claude structure"
$claudeHome = Join-Path $env:USERPROFILE '.claude'
foreach ($dir in @($claudeHome,
                   (Join-Path $claudeHome 'agents'),
                   (Join-Path $claudeHome 'commands'),
                   (Join-Path $claudeHome 'skills'))) {
    if (-not (Test-Path -LiteralPath $dir)) {
        Invoke-Step "Create $dir" { New-Item -ItemType Directory -Path $dir -Force | Out-Null } | Out-Null
    }
}

# Global memory file - loaded by every Claude Code session for this user.
$globalMd = Join-Path $claudeHome 'CLAUDE.md'
if (-not (Test-Path -LiteralPath $globalMd)) {
    $globalMdContent = @'
# Global Claude Code Memory (all projects)

## Machine facts
- Windows 11 Pro laptop, AMD Ryzen AI 9 HX 375, PowerShell is the default shell.
- Git Bash lives at the path in CLAUDE_CODE_GIT_BASH_PATH; never assume WSL.
- Prefer PowerShell (.ps1) for system scripts, Python for tools.

## Working style
- Before proposing a custom build, check for an existing tool/library first.
- When you correct a mistake, add a one-line lesson under ## Lessons.
- Keep answers concise; lead with the outcome.

## Lessons
- (add one-line lessons here as they are learned)
'@
    Invoke-Step "Write $globalMd" { $globalMdContent | Out-File -FilePath $globalMd -Encoding ASCII } | Out-Null
} else {
    Write-Ok "Global CLAUDE.md already exists - not touching it."
}

# settings.json - create only if absent; otherwise write settings.suggested.json.
$settingsPath = Join-Path $claudeHome 'settings.json'
$settingsTarget = $settingsPath
if (Test-Path -LiteralPath $settingsPath) {
    $settingsTarget = Join-Path $claudeHome 'settings.suggested.json'
    Write-Warn2 "settings.json exists - writing suggestions to settings.suggested.json instead (merge by hand)."
}
$settingsObj = [ordered]@{
    permissions = [ordered]@{
        allow = @(
            'Bash(git status:*)', 'Bash(git diff:*)', 'Bash(git log:*)',
            'Bash(python --version)', 'Bash(node --version)'
        )
        additionalDirectories = @()
    }
}
if ($GrantBroadFileAccess) {
    $granted = @()
    foreach ($p in $AccessPaths) {
        if (Test-Path -LiteralPath $p) { $granted += $p } else { Write-Warn2 "Access path not found, skipping: $p" }
    }
    $settingsObj.permissions.additionalDirectories = $granted
    Write-Warn2 "Broad file access requested for: $($granted -join ', ')"
    Write-Warn2 "Every Claude Code session can now reach these trees (subject to permission mode)."
}
if (($settingsTarget -ne $settingsPath) -or -not (Test-Path -LiteralPath $settingsPath)) {
    Invoke-Step "Write $settingsTarget" {
        ($settingsObj | ConvertTo-Json -Depth 6) | Out-File -FilePath $settingsTarget -Encoding ASCII
    } | Out-Null
}

# If broad access was requested and settings.json already existed, patch it in place
# (additive only - never removes anything you configured).
if ($GrantBroadFileAccess -and (Test-Path -LiteralPath $settingsPath) -and ($settingsTarget -ne $settingsPath) -and -not $DryRun) {
    try {
        $existing = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($null -eq $existing.permissions) {
            $existing | Add-Member -MemberType NoteProperty -Name permissions -Value ([pscustomobject]@{ additionalDirectories = @() })
        }
        $currentDirs = @()
        if ($null -ne $existing.permissions.PSObject.Properties['additionalDirectories']) {
            $currentDirs = @($existing.permissions.additionalDirectories)
        } else {
            $existing.permissions | Add-Member -MemberType NoteProperty -Name additionalDirectories -Value @()
        }
        $merged = @($currentDirs + $settingsObj.permissions.additionalDirectories | Select-Object -Unique)
        $existing.permissions.additionalDirectories = $merged
        ($existing | ConvertTo-Json -Depth 10) | Out-File -FilePath $settingsPath -Encoding ASCII
        Write-Ok "Merged additionalDirectories into existing settings.json (backup: settings.suggested.json shows what was added)."
    } catch {
        Write-Warn2 "Could not auto-merge settings.json ($($_.Exception.Message)) - merge settings.suggested.json manually."
    }
}

# ============================================================
# 8. Verification
# ============================================================
Write-Section "8/8 Verification"
Update-SessionPath
$checks = @(
    @{ Name = 'git';        Cmd = { git --version } },
    @{ Name = 'git lfs';    Cmd = { git lfs version } },
    @{ Name = 'git-bash';   Cmd = { & ([Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH','User')) --version } },
    @{ Name = 'node';       Cmd = { node --version } },
    @{ Name = 'npm';        Cmd = { npm --version } },
    @{ Name = 'python';     Cmd = { python --version } },
    @{ Name = 'claude';     Cmd = { claude --version } },
    @{ Name = 'agent-sdk';  Cmd = { python -c "import claude_agent_sdk; print('claude-agent-sdk ' + claude_agent_sdk.__version__)" } }
)
foreach ($check in $checks) {
    if ($DryRun) { Write-Host ("  [DRYRUN] verify " + $check.Name) -ForegroundColor Magenta; continue }
    try {
        $out = (& $check.Cmd 2>&1 | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -or "$out" -match '\d') { Write-Ok ("{0,-10} {1}" -f $check.Name, $out) }
        else { Write-Bad ("{0,-10} {1}" -f $check.Name, $out); $failures++ }
    } catch { Write-Bad ("{0,-10} {1}" -f $check.Name, $_.Exception.Message); $failures++ }
}

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Cyan
if ($failures -gt 0) {
    Write-Warn2 "$failures step(s) need attention (see above). Most PATH-related ones resolve after reopening the terminal and rerunning."
}
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. CLOSE and REOPEN all terminals + Claude Code (env vars need new processes)."
Write-Host "  2. Run 'claude' in a project folder and sign in."
Write-Host "  3. Run Setup-ClaudeFolders.ps1 in each project root for the .claude structure."
Write-Host "  4. Run Verify-ClaudeCodeSetup.ps1 any time to re-check the whole chain."
exit $failures
