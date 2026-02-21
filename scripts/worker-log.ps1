# worker-log.ps1 - ログを表示する（ConPTY + サーバー）
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"

# Try ConPTY log via pipe
try { & $ctl log } catch { Write-Host "(claude-ctl log unavailable)" }

# Always show server log too
Write-Host ""
Write-Host "=== Server Log (last 30 lines) ==="
$serverLog = Join-Path $projectRoot "logs\server.log"
if (Test-Path $serverLog) {
    Get-Content $serverLog -Tail 30
} else {
    Write-Host "(not found)"
}
