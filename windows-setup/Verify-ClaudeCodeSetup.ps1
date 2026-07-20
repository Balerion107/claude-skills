<#
.SYNOPSIS
    Quick health check for the whole Claude Code toolchain on Windows.
    Read-only - changes nothing. Exit code = number of failed checks.

.EXAMPLE
    .\Verify-ClaudeCodeSetup.ps1
#>

[CmdletBinding()]
param()

$fail = 0
function Check {
    param([string]$Name, [scriptblock]$Probe, [string]$FixHint)
    try {
        $out = & $Probe 2>&1 | Select-Object -First 1
        if ($null -ne $out -and "$out" -ne '' -and "$out" -notmatch 'not recognized|cannot find|CommandNotFound') {
            Write-Host ("[OK]   {0,-28} {1}" -f $Name, $out) -ForegroundColor Green
            return
        }
        throw "no output"
    } catch {
        Write-Host ("[FAIL] {0,-28} fix: {1}" -f $Name, $FixHint) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "=== Claude Code Setup Verification ===" -ForegroundColor Cyan

Check 'git'       { git --version }        'Install-ClaudeCodeEnvironment.ps1'
Check 'git lfs'   { git lfs version }      'winget install --id GitHub.GitLFS -e; git lfs install'
Check 'node'      { node --version }       'winget install --id OpenJS.NodeJS.LTS -e'
Check 'npm'       { npm --version }        'reopen terminal after Node install'
Check 'python'    { python --version }     'winget install --id Python.Python.3.12 -e'
Check 'claude'    { claude --version }     'irm https://claude.ai/install.ps1 | iex'
Check 'agent-sdk' { python -c "import claude_agent_sdk; print('claude-agent-sdk OK')" } 'python -m pip install claude-agent-sdk'

# git-bash wiring: the env var must be set AND point at an existing bash.exe AND run.
$bashVar = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
if ([string]::IsNullOrEmpty($bashVar)) {
    Write-Host "[FAIL] CLAUDE_CODE_GIT_BASH_PATH     not set - run Fix-GitForWindows-ClaudeCode.ps1 -Apply" -ForegroundColor Red
    $fail++
} elseif (-not (Test-Path -LiteralPath $bashVar)) {
    Write-Host "[FAIL] CLAUDE_CODE_GIT_BASH_PATH     points at missing file: $bashVar" -ForegroundColor Red
    $fail++
} else {
    Check 'git-bash (env var)' { & $bashVar --version } 'Fix-GitForWindows-ClaudeCode.ps1 -Apply'
}

# Multiple-install sniff test
try {
    $gitHits = @(where.exe git.exe 2>$null)
    if ($gitHits.Count -gt 1) {
        Write-Host ("[WARN] {0} git.exe copies on PATH - see Fix-GitForWindows-ClaudeCode.ps1 report" -f $gitHits.Count) -ForegroundColor Yellow
        $gitHits | ForEach-Object { Write-Host "        $_" -ForegroundColor Yellow }
    }
} catch { }

# Global structure
$claudeHome = Join-Path $env:USERPROFILE '.claude'
foreach ($p in @($claudeHome, (Join-Path $claudeHome 'CLAUDE.md'))) {
    if (Test-Path -LiteralPath $p) {
        Write-Host ("[OK]   {0,-28} exists" -f $p.Replace($env:USERPROFILE, '~')) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0,-28} missing - run Install-ClaudeCodeEnvironment.ps1" -f $p.Replace($env:USERPROFILE, '~')) -ForegroundColor Red
        $fail++
    }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "All checks passed. Claude Code toolchain is healthy." -ForegroundColor Green }
else             { Write-Host "$fail check(s) failed - hints above." -ForegroundColor Yellow }
exit $fail
