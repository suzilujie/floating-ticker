# build.ps1 - One-click build & push to trigger CI
#
# Usage (run in PowerShell):
#   .\build.ps1                        commit changes & push (skips if no changes)
#   .\build.ps1 -Message "feat: xxx"   custom commit message
#   .\build.ps1 -Wait                  also wait for CI and print result + install link
#   .\build.ps1 -Empty                 push an empty commit (e.g. after editing secrets only)
#
# Tip: double-click build.bat to run without worrying about execution policy.

param(
    [string]$Message = "",
    [switch]$Wait,
    [switch]$Empty
)

$Owner    = "suzilujie"
$Repo     = "floating-ticker"
$RepoFull = "$Owner/$Repo"

# Project root = directory containing this script
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host ""
Write-Host "=== One-click build ===" -ForegroundColor Cyan
Write-Host "Project: $(Get-Location)"

# --- helper: run a git command, fail on non-zero exit code ---
function Invoke-Git([string[]]$GitArgs) {
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) { Write-Host $line }
    if ($code -ne 0) {
        Write-Host ("git " + ($GitArgs -join ' ') + " failed (exit $code)") -ForegroundColor Red
        exit 1
    }
}

# [1/4] Stage
Write-Host ""
Write-Host "[1/4] Staging changes..." -ForegroundColor Yellow
Invoke-Git @("add", "-A")
$changes = @(git status --porcelain)

# [2/4] Commit
$pushed = $false
if ($changes.Count -gt 0) {
    if (-not $Message) { $Message = "build: one-click $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
    Write-Host "[2/4] Committing: $Message" -ForegroundColor Yellow
    Invoke-Git @("commit", "-m", $Message)
    $pushed = $true
}
elseif ($Empty) {
    if (-not $Message) { $Message = "build: empty commit $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
    Write-Host "[2/4] No changes; pushing empty commit: $Message" -ForegroundColor Yellow
    Invoke-Git @("commit", "--allow-empty", "-m", $Message)
    $pushed = $true
}
else {
    Write-Host "[2/4] No local changes. Nothing to commit." -ForegroundColor Gray
    Write-Host "      Tip: use -Empty to trigger a build after editing secrets only." -ForegroundColor Gray
}

# [3/4] Push
if ($pushed) {
    Write-Host "[3/4] Pushing to origin/main..." -ForegroundColor Yellow
    $env:GIT_TERMINAL_PROMPT = "0"
    Invoke-Git @("push", "origin", "main")
    $sha = (git rev-parse HEAD).Substring(0, 7)
    Write-Host "Pushed: $sha" -ForegroundColor Green
}
else {
    Write-Host "[3/4] Nothing to push. Done." -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# [4/4] Wait for CI (optional)
if ($Wait) {
    Write-Host ""
    Write-Host "[4/4] Waiting for GitHub Actions..." -ForegroundColor Yellow
    $headers = @{ 'User-Agent' = 'build-script' }
    $deadline = (Get-Date).AddMinutes(12)
    $done = $false
    while (-not $done -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try {
            $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoFull/actions/runs?per_page=10" -Headers $headers -TimeoutSec 25
            $mine = @($r.workflow_runs | Where-Object { $_.head_sha -like "$sha*" })
            $running = @($mine | Where-Object { $_.status -in @('queued', 'in_progress', 'waiting') })
            if ($mine.Count -gt 0 -and $running.Count -eq 0) {
                Write-Host ""
                Write-Host "=== Build results ===" -ForegroundColor Cyan
                foreach ($run in $mine) {
                    $color = if ($run.conclusion -eq 'success') { 'Green' } else { 'Red' }
                    Write-Host ("{0,-14} -> {1}" -f $run.name, $run.conclusion) -ForegroundColor $color
                }
                Write-Host ""
                Write-Host "Install link (open in iPhone Safari):" -ForegroundColor Green
                Write-Host "itms-services://?action=download-manifest&url=https://${Owner}.github.io/${Repo}/manifest.plist"
                $done = $true
            }
        }
        catch {
            Write-Host ("  query failed, retrying... (" + $_.Exception.Message + ")") -ForegroundColor Gray
        }
    }
    if (-not $done) { Write-Host "Timed out waiting for CI. Check the Actions tab manually." -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
