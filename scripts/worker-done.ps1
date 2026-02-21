# worker-done.ps1 - Claudeワーカーを終了する（プロセス停止＋クリーンアップ）
$ErrorActionPreference = "Stop"
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"

# Graceful shutdown via pipe, then force cleanup
try { & $ctl send "/exit" } catch { }
Start-Sleep -Seconds 2

$projectRoot = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $projectRoot "logs\.claude_pid"
$serverPidFile = Join-Path $projectRoot "logs\.claude_server_pid"

# Stop server process
if (Test-Path $serverPidFile) {
    $serverPid = Get-Content $serverPidFile -Raw
    try { Stop-Process -Id ([int]$serverPid) -Force -ErrorAction SilentlyContinue } catch { }
    Remove-Item $serverPidFile -Force -ErrorAction SilentlyContinue
}

# Stop Claude process
if (Test-Path $pidFile) {
    $claudePid = Get-Content $pidFile -Raw
    try { Stop-Process -Id ([int]$claudePid) -Force -ErrorAction SilentlyContinue } catch { }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

Write-Host "RESULT: Claude worker has been stopped"
