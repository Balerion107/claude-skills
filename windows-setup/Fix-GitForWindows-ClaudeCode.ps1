<#
.SYNOPSIS
    Diagnostic + safe repair toolkit for messy Git for Windows / Git LFS / Git Bash
    installations that break Claude Code on Windows.

.DESCRIPTION
    Finds every Git installation on the machine using fast, targeted discovery
    (known install roots, registry, where.exe, PATH) instead of a full-drive crawl.
    Picks the best Git Bash candidate, validates it actually runs, and writes a
    markdown diagnostic report.

    With -Apply it then:
      1. Sets CLAUDE_CODE_GIT_BASH_PATH (User scope) to the validated bash.exe
         - the #1 fix for "Claude Code requires git-bash" errors on Windows.
      2. Optionally (-CleanUserPath) removes User-PATH entries that point at
         OTHER Git installs, keeping only the chosen one. User PATH only;
         Machine PATH is never modified (reported instead).
      3. Refreshes Git LFS hooks using the CHOSEN git.exe explicitly (so the
         right install gets the hooks even if PATH still resolves elsewhere).

    Everything is backed up first (PATH, env vars, gitconfig files) to a
    timestamped folder, and every change is printed before it is made.

    Default mode is diagnose-only. Nothing changes without -Apply.

.PARAMETER Apply
    Actually perform repairs. Without this switch the script only diagnoses.

.PARAMETER CleanUserPath
    With -Apply: remove User-PATH entries belonging to non-chosen Git installs
    and de-duplicate the User PATH. Machine PATH is reported but never touched.

.PARAMETER DeepScan
    Also crawl common install roots (depth-limited, single pass) for stray
    git.exe / bash.exe / git-lfs.exe copies. Slower; use when the fast scan
    misses a portable install.

.PARAMETER LogPath
    Transcript log path. Defaults to a timestamped file next to the script.

.PARAMETER BackupRoot
    Root folder for backups. A timestamped subfolder is created per run.

.EXAMPLE
    .\Fix-GitForWindows-ClaudeCode.ps1
    # Diagnose only (always run this first, read the report)

.EXAMPLE
    .\Fix-GitForWindows-ClaudeCode.ps1 -Apply
    # Set CLAUDE_CODE_GIT_BASH_PATH + refresh LFS hooks

.EXAMPLE
    .\Fix-GitForWindows-ClaudeCode.ps1 -Apply -CleanUserPath
    # Also remove duplicate/conflicting Git entries from the User PATH

.NOTES
    Works in Windows PowerShell 5.1 and PowerShell 7+. Admin NOT required:
    everything it changes is User-scope. After -Apply, fully close and reopen
    Claude Code and all terminals so they pick up the new environment.
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$CleanUserPath,
    [switch]$DeepScan,
    [string]$LogPath = "",
    [string]$BackupRoot = ""
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

# $PSScriptRoot is empty when pasted into a console - fall back to CWD.
$scriptHome = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptHome)) { $scriptHome = (Get-Location).Path }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrEmpty($LogPath))    { $LogPath    = Join-Path $scriptHome ("GitFixer_{0}.log" -f $timestamp) }
if ([string]::IsNullOrEmpty($BackupRoot)) { $BackupRoot = Join-Path $scriptHome 'Backups' }
$backupDir  = Join-Path $BackupRoot $timestamp
$reportPath = Join-Path $scriptHome ("GitFixer_Report_{0}.md" -f $timestamp)

function Write-Section { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2   { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Bad     { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info    { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }

function Invoke-Exe {
    # Run an exe, capture first line of output, never throw.
    param([string]$Path, [string[]]$Arguments)
    try {
        $out = & $Path @Arguments 2>&1 | Select-Object -First 1
        if ($null -ne $out) { return [string]$out }
        return ""
    } catch { return "" }
}

Start-Transcript -Path $LogPath -Append | Out-Null
try {

Write-Host "=== Git for Windows + Claude Code Repair Toolkit ===" -ForegroundColor Cyan
if ($Apply) { Write-Host "Mode: LIVE REPAIR" -ForegroundColor Yellow }
else        { Write-Host "Mode: DIAGNOSE ONLY (rerun with -Apply to fix)" -ForegroundColor Yellow }
Write-Host "Log:  $LogPath"

# ============================================================
# 1. BACKUP CURRENT STATE
# ============================================================
Write-Section "1/6 Backing up current state"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

[Environment]::GetEnvironmentVariable('Path', 'User')    | Out-File -FilePath (Join-Path $backupDir 'PATH_user.txt')    -Encoding UTF8
[Environment]::GetEnvironmentVariable('Path', 'Machine') | Out-File -FilePath (Join-Path $backupDir 'PATH_machine.txt') -Encoding UTF8

$envBackup = @{}
foreach ($var in @('CLAUDE_CODE_GIT_BASH_PATH', 'GIT_EXEC_PATH', 'GIT_CONFIG_NOSYSTEM', 'HOME')) {
    $envBackup[$var] = [Environment]::GetEnvironmentVariable($var, 'User')
}
$envBackup | ConvertTo-Json | Out-File -FilePath (Join-Path $backupDir 'env_user_backup.json') -Encoding UTF8

# NOTE: ${env:ProgramFiles(x86)} needs the brace syntax - "$env:ProgramFiles (x86)"
# silently expands to "C:\Program Files (x86)" only by accident and breaks in paths.
$gitconfigLocations = @(
    (Join-Path $env:USERPROFILE '.gitconfig'),
    (Join-Path $env:USERPROFILE '.config\git\config'),
    (Join-Path $env:ProgramFiles 'Git\etc\gitconfig'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\etc\gitconfig'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\etc\gitconfig')
)
foreach ($loc in $gitconfigLocations) {
    if (Test-Path -LiteralPath $loc) {
        $safeName = ($loc -replace '[:\\]', '_')
        Copy-Item -LiteralPath $loc -Destination (Join-Path $backupDir $safeName) -Force -ErrorAction SilentlyContinue
    }
}
Write-Ok "Backups saved to: $backupDir"

# ============================================================
# 2. DISCOVER GIT INSTALLATIONS (fast, targeted)
# ============================================================
Write-Section "2/6 Discovering Git installations"

$rootCandidates = New-Object System.Collections.Generic.List[string]

# a) Known install roots
foreach ($p in @(
    (Join-Path $env:ProgramFiles 'Git'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git'),
    (Join-Path $env:USERPROFILE 'scoop\apps\git\current'),
    (Join-Path $env:SystemDrive '\Git'),
    (Join-Path $env:SystemDrive '\PortableGit'),
    (Join-Path $env:SystemDrive '\tools\git')
)) { $rootCandidates.Add($p) }

# b) Registry (both hives + WOW6432Node)
foreach ($regPath in @(
    'HKLM:\SOFTWARE\GitForWindows',
    'HKLM:\SOFTWARE\WOW6432Node\GitForWindows',
    'HKCU:\SOFTWARE\GitForWindows'
)) {
    $reg = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($null -ne $reg -and $reg.PSObject.Properties['InstallPath']) {
        $rootCandidates.Add([string]$reg.InstallPath)
    }
}

# c) where.exe resolution (what PATH currently wins with)
$whereGit = @()
try { $whereGit = @(where.exe git.exe 2>$null) } catch { }
foreach ($hit in $whereGit) {
    $parent = Split-Path -Parent $hit
    # ...\Git\cmd\git.exe or ...\Git\bin\git.exe -> root is one level up
    if ((Split-Path -Leaf $parent) -in @('cmd', 'bin')) {
        $rootCandidates.Add((Split-Path -Parent $parent))
    }
}

# d) PATH entries that look git-related
$combinedPath = ($env:PATH -split ';') | Where-Object { $_ -and ($_ -match '(?i)git') }
foreach ($entry in $combinedPath) {
    $trimmed = $entry.TrimEnd('\')
    if ((Split-Path -Leaf $trimmed) -in @('cmd', 'bin')) {
        $rootCandidates.Add((Split-Path -Parent $trimmed))
    } elseif ($trimmed -match '(?i)\\git$') {
        $rootCandidates.Add($trimmed)
    }
}

# e) GitHub Desktop's bundled git (common hidden duplicate)
$ghDesktop = Join-Path $env:LOCALAPPDATA 'GitHubDesktop'
if (Test-Path -LiteralPath $ghDesktop) {
    Get-ChildItem -Path $ghDesktop -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object {
        $bundled = Join-Path $_.FullName 'resources\app\git'
        if (Test-Path -LiteralPath $bundled) { $rootCandidates.Add($bundled) }
    }
}

# f) Optional depth-limited deep scan (single pass, -Include, never whole-drive)
if ($DeepScan) {
    Write-Info "Deep scan enabled (depth-limited, this can take a few minutes)..."
    $deepRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)},
                   (Join-Path $env:LOCALAPPDATA 'Programs'), $env:USERPROFILE) |
                 Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($dr in $deepRoots) {
        Get-ChildItem -Path $dr -Recurse -Depth 5 -Include 'git.exe' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $parent = Split-Path -Parent $_.FullName
                if ((Split-Path -Leaf $parent) -in @('cmd', 'bin')) {
                    $rootCandidates.Add((Split-Path -Parent $parent))
                }
            }
    }
}

# Normalize + validate roots: a real Git-for-Windows root has cmd\git.exe or bin\git.exe
$gitInstalls = @()
$seen = @{}
foreach ($root in $rootCandidates) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $norm = $root.TrimEnd('\')
    $key = $norm.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (-not (Test-Path -LiteralPath $norm)) { continue }

    $gitExe = $null
    foreach ($rel in @('cmd\git.exe', 'bin\git.exe')) {
        $probe = Join-Path $norm $rel
        if (Test-Path -LiteralPath $probe) { $gitExe = $probe; break }
    }
    if ($null -eq $gitExe) { continue }

    $bashExe = $null
    foreach ($rel in @('bin\bash.exe', 'usr\bin\bash.exe')) {
        $probe = Join-Path $norm $rel
        if (Test-Path -LiteralPath $probe) { $bashExe = $probe; break }
    }

    $version = Invoke-Exe -Path $gitExe -Arguments @('--version')
    $gitInstalls += [pscustomobject]@{
        Root    = $norm
        GitExe  = $gitExe
        BashExe = $bashExe
        Version = $version
    }
}

if ($gitInstalls.Count -eq 0) {
    Write-Bad "No Git for Windows installation found at all."
    Write-Info "Run Install-ClaudeCodeEnvironment.ps1 (same folder) to install Git + everything else, then rerun this script."
} else {
    foreach ($gi in $gitInstalls) {
        Write-Info ("Found: {0}  ({1})" -f $gi.Root, $gi.Version)
    }
    if ($gitInstalls.Count -gt 1) {
        Write-Warn2 ("{0} separate Git installations found - this is the usual cause of Claude Code git-bash errors." -f $gitInstalls.Count)
    }
}

# WSL bash conflict check: PATH may resolve 'bash' to the WSL launcher, which
# Claude Code cannot use. Harmless once CLAUDE_CODE_GIT_BASH_PATH is set.
$wslBashInPath = $false
$bashCmd = Get-Command bash.exe -ErrorAction SilentlyContinue
if ($null -ne $bashCmd -and $bashCmd.Source -match '(?i)\\system32\\') { $wslBashInPath = $true }

# ============================================================
# 3. PICK + VALIDATE THE BEST GIT BASH
# ============================================================
Write-Section "3/6 Selecting best Git Bash"

$scored = @()
foreach ($gi in $gitInstalls) {
    if ($null -eq $gi.BashExe) { continue }
    $score = 0
    if ($gi.BashExe -match '(?i)^C:\\Program Files\\Git\\bin\\bash\.exe$') { $score += 100 }
    elseif ($gi.Root -match '(?i)\\Programs\\Git$')                        { $score += 60 }
    elseif ($gi.Root -match '(?i)scoop')                                   { $score += 40 }
    elseif ($gi.Root -match '(?i)GitHubDesktop')                           { $score += 5 }
    else                                                                   { $score += 20 }
    # Prefer bin\bash.exe (the wrapper Claude Code documents) over usr\bin\bash.exe
    if ($gi.BashExe -match '(?i)\\usr\\bin\\bash\.exe$') { $score -= 20 }

    # Must actually run
    $bashVer = Invoke-Exe -Path $gi.BashExe -Arguments @('--version')
    if ($bashVer -notmatch 'bash') { $score = -1 }

    $scored += [pscustomobject]@{ Install = $gi; Score = $score; BashVersion = $bashVer }
}

$best = $scored | Where-Object { $_.Score -ge 0 } | Sort-Object Score -Descending | Select-Object -First 1
$chosenBash = $null
$chosenGit  = $null
$chosenRoot = $null
if ($null -ne $best) {
    $chosenBash = $best.Install.BashExe
    $chosenGit  = $best.Install.GitExe
    $chosenRoot = $best.Install.Root
    Write-Ok ("Chosen bash: {0}" -f $chosenBash)
    Write-Info ("  {0}" -f $best.BashVersion)
} else {
    Write-Bad "No working Git Bash found. Claude Code will fail until one is installed."
}

$currentEnvVar = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')

# ============================================================
# 4. REPORT
# ============================================================
Write-Section "4/6 Writing diagnostic report"

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("# Git for Windows + Claude Code Diagnostic Report")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- **Generated:** $(Get-Date)")
$null = $sb.AppendLine("- **Machine:** $env:COMPUTERNAME  **User:** $env:USERNAME")
$modeText = 'Diagnose only'
if ($Apply) { $modeText = 'Repair applied' }
$null = $sb.AppendLine("- **Mode:** $modeText")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Git installations found ($($gitInstalls.Count))")
$null = $sb.AppendLine("")
foreach ($gi in $gitInstalls) {
    $bashText = '(no bash.exe!)'
    if ($null -ne $gi.BashExe) { $bashText = $gi.BashExe }
    $null = $sb.AppendLine("- ``$($gi.Root)`` - $($gi.Version) - bash: ``$bashText``")
}
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Verdicts")
$null = $sb.AppendLine("")
if ($gitInstalls.Count -eq 0) { $null = $sb.AppendLine("- FAIL: No Git installation. Run Install-ClaudeCodeEnvironment.ps1 first.") }
if ($gitInstalls.Count -gt 1) { $null = $sb.AppendLine("- WARN: Multiple Git installations ($($gitInstalls.Count)). Keep one (prefer C:\Program Files\Git), uninstall the rest via Settings > Apps.") }
if ($null -ne $chosenBash)    { $null = $sb.AppendLine("- OK: Working Git Bash selected: ``$chosenBash``") }
else                          { $null = $sb.AppendLine("- FAIL: No working Git Bash found.") }
if ([string]::IsNullOrEmpty($currentEnvVar)) { $null = $sb.AppendLine("- WARN: CLAUDE_CODE_GIT_BASH_PATH is NOT set (the #1 Claude Code Windows fix).") }
elseif ($currentEnvVar -ne $chosenBash)      { $null = $sb.AppendLine("- WARN: CLAUDE_CODE_GIT_BASH_PATH points to ``$currentEnvVar`` but best candidate is ``$chosenBash``.") }
else                                         { $null = $sb.AppendLine("- OK: CLAUDE_CODE_GIT_BASH_PATH already correct.") }
if ($wslBashInPath) { $null = $sb.AppendLine("- INFO: PATH resolves ``bash`` to the WSL launcher (System32). Fine once CLAUDE_CODE_GIT_BASH_PATH is set; Claude Code will use the explicit path.") }
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## PATH entries that are Git-related")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("### User PATH")
foreach ($e in (([Environment]::GetEnvironmentVariable('Path','User')) -split ';')) {
    if ($e -match '(?i)git') { $null = $sb.AppendLine("- ``$e``") }
}
$null = $sb.AppendLine("")
$null = $sb.AppendLine("### Machine PATH (never modified by this script)")
foreach ($e in (([Environment]::GetEnvironmentVariable('Path','Machine')) -split ';')) {
    if ($e -match '(?i)git') { $null = $sb.AppendLine("- ``$e``") }
}
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Next steps")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("1. Review this report. If the chosen bash looks right, rerun with ``-Apply``.")
$null = $sb.AppendLine("2. Add ``-CleanUserPath`` to also strip duplicate Git entries from the User PATH.")
$null = $sb.AppendLine("3. Uninstall extra Git copies via Settings > Apps (this script never deletes installs).")
$null = $sb.AppendLine("4. Fully close and reopen Claude Code and all terminals afterwards.")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("Backups: ``$backupDir``  |  Log: ``$LogPath``")

$sb.ToString() | Out-File -FilePath $reportPath -Encoding UTF8
Write-Ok "Report: $reportPath"

# ============================================================
# 5. REPAIR (only with -Apply)
# ============================================================
Write-Section "5/6 Repair"

if (-not $Apply) {
    Write-Info "Diagnose-only mode: no changes made. Rerun with -Apply after reviewing the report."
} elseif ($null -eq $chosenBash) {
    Write-Bad "Nothing to apply: no working Git Bash was found. Install Git first (Install-ClaudeCodeEnvironment.ps1)."
} else {
    # 5a. CLAUDE_CODE_GIT_BASH_PATH
    if ($currentEnvVar -eq $chosenBash) {
        Write-Ok "CLAUDE_CODE_GIT_BASH_PATH already set correctly."
    } else {
        Write-Host "  Setting CLAUDE_CODE_GIT_BASH_PATH -> $chosenBash" -ForegroundColor Cyan
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $chosenBash, 'User')
        $env:CLAUDE_CODE_GIT_BASH_PATH = $chosenBash   # current session too
        Write-Ok "CLAUDE_CODE_GIT_BASH_PATH set (User scope)."
    }

    # 5b. Optional User PATH cleanup
    if ($CleanUserPath) {
        $userPathRaw = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @($userPathRaw -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $kept = New-Object System.Collections.Generic.List[string]
        $dropped = @()
        $seenEntry = @{}
        foreach ($entry in $entries) {
            $norm = $entry.TrimEnd('\')
            $lower = $norm.ToLowerInvariant()
            if ($seenEntry.ContainsKey($lower)) { $dropped += "$entry  (duplicate)"; continue }
            $seenEntry[$lower] = $true
            $isGitEntry = $norm -match '(?i)\\git(\\|$)|gitforwindows|portablegit'
            $underChosen = $lower.StartsWith($chosenRoot.ToLowerInvariant())
            if ($isGitEntry -and -not $underChosen) {
                $dropped += "$entry  (points at a non-chosen Git install)"
                continue
            }
            $kept.Add($entry)
        }
        # Make sure the chosen install's cmd dir is on the User PATH if no
        # Machine-PATH entry already covers it.
        $chosenCmd = Join-Path $chosenRoot 'cmd'
        $machineHasIt = @(([Environment]::GetEnvironmentVariable('Path','Machine')) -split ';' |
            Where-Object { $_.TrimEnd('\').ToLowerInvariant() -eq $chosenCmd.ToLowerInvariant() }).Count -gt 0
        $userHasIt = @($kept | Where-Object { $_.TrimEnd('\').ToLowerInvariant() -eq $chosenCmd.ToLowerInvariant() }).Count -gt 0
        if (-not $machineHasIt -and -not $userHasIt) {
            $kept.Add($chosenCmd)
            Write-Info "Adding to User PATH: $chosenCmd"
        }

        if ($dropped.Count -gt 0) {
            Write-Host "  Removing from User PATH:" -ForegroundColor Yellow
            foreach ($d in $dropped) { Write-Info "  - $d" }
            [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
            Write-Ok "User PATH cleaned ($($dropped.Count) entries removed). Original saved in backup folder."
        } else {
            Write-Ok "User PATH already clean - nothing removed."
        }
    }

    # 5c. Git LFS - use the CHOSEN git explicitly, not whatever PATH resolves.
    $lfsVer = Invoke-Exe -Path $chosenGit -Arguments @('lfs', 'version')
    if ($lfsVer -match 'git-lfs') {
        & $chosenGit lfs install --skip-repo 2>&1 | Out-Null
        Write-Ok "Git LFS hooks refreshed for chosen install ($lfsVer)."
    } else {
        Write-Warn2 "Chosen Git has no LFS. Install it: winget install --id GitHub.GitLFS -e ; then rerun with -Apply."
    }

    # 5d. Long paths - saves you from checkout failures on deep node_modules trees.
    & $chosenGit config --global core.longpaths true 2>&1 | Out-Null
    Write-Ok "git config --global core.longpaths true"
}

# ============================================================
# 6. VERIFICATION
# ============================================================
Write-Section "6/6 Verification"

if ($null -ne $chosenGit) {
    Write-Info ("chosen git : " + (Invoke-Exe -Path $chosenGit -Arguments @('--version')))
    Write-Info ("chosen lfs : " + (Invoke-Exe -Path $chosenGit -Arguments @('lfs', 'version')))
}
if ($null -ne $chosenBash) {
    Write-Info ("chosen bash: " + (Invoke-Exe -Path $chosenBash -Arguments @('--version')))
}
$finalVar = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
Write-Info ("CLAUDE_CODE_GIT_BASH_PATH (User) = " + $finalVar)

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Report : $reportPath"
Write-Host "Backups: $backupDir"
if (-not $Apply) {
    Write-Host "No changes were made. Review the report, then rerun with -Apply." -ForegroundColor White
} else {
    Write-Host "Done. FULLY close and reopen Claude Code and every terminal window now -" -ForegroundColor White
    Write-Host "environment variable changes are only picked up by new processes." -ForegroundColor White
}

} finally {
    Stop-Transcript | Out-Null
}
