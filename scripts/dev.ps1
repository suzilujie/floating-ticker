# ============================================================
# dev.ps1 - FloatingTicker development helper (Windows)
#
# Usage:
#   .\scripts\dev.ps1 push "commit message"   # git add + commit + push
#   .\scripts\dev.ps1 ci                       # show latest CI runs
#   .\scripts\dev.ps1 watch                    # watch latest run until done
#
# Notes:
#   - push requires VPN/proxy to reach github.com
#   - CI query uses the system proxy and retries on flaky links
# ============================================================

param(
    [Parameter(Position = 0)]
    [ValidateSet('push', 'ci', 'watch')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Api = 'https://api.github.com/repos/suzilujie/floating-ticker'
$Headers = @{ 'User-Agent' = 'dev-script' }

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$Attempts = 6,
        [int]$DelaySeconds = 4
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            return & $ScriptBlock
        }
        catch {
            Write-Host ("  [retry {0}/{1}] {2}" -f $i, $Attempts, $_.Exception.Message)
            if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
        }
    }
    throw "all $Attempts attempts failed"
}

function Get-Runs {
    Invoke-WithRetry { Invoke-RestMethod -Uri "$Api/actions/runs?per_page=5" -Headers $Headers -TimeoutSec 15 }
}

function Show-Ci {
    $r = Get-Runs
    $r.workflow_runs | ForEach-Object {
        Write-Output ("{0}  sha={1}  status={2}  conclusion={3}" -f $_.id, $_.head_sha.Substring(0, 7), $_.status, $_.conclusion)
    }
}

function Watch-Ci {
    $r = Get-Runs
    $run = $r.workflow_runs | Select-Object -First 1
    Write-Output ("watching run {0} (sha {1})..." -f $run.id, $run.head_sha.Substring(0, 7))

    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $detail = Invoke-WithRetry { Invoke-RestMethod -Uri "$Api/actions/runs/$($run.id)" -Headers $Headers -TimeoutSec 15 }
        if ($detail.status -notin @('queued', 'in_progress')) {
            Write-Output ("done: status={0} conclusion={1}" -f $detail.status, $detail.conclusion)
            return
        }
        Write-Output '  still running...'
    }
    Write-Output 'timeout watching run (still running after 5 min)'
}

Set-Location $Repo

switch ($Command) {
    'push' {
        if (-not $Message) {
            throw 'usage: .\scripts\dev.ps1 push "commit message"'
        }
        git add -A
        git commit -m $Message
        git push origin main
    }
    'ci'    { Show-Ci }
    'watch' { Watch-Ci }
    default {
        Write-Output 'usage: .\scripts\dev.ps1 [push|ci|watch]'
        Write-Output '  push "msg"  -> add + commit + push'
        Write-Output '  ci          -> list latest CI runs'
        Write-Output '  watch       -> wait for the latest run to finish'
    }
}
