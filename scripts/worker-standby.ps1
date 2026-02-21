# worker-standby.ps1 - Claudeの作業完了を待機する
param([int]$Timeout = 3600)
$ErrorActionPreference = "Stop"
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"
& $ctl wait -Timeout $Timeout
if (Test-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "logs\.claude_done")) {
    Write-Host "RESULT: Claude has completed the task"
} else {
    Write-Host "RESULT: Timeout - Claude did not complete within ${Timeout}s"
}
