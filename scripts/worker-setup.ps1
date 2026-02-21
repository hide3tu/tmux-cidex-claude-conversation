# worker-setup.ps1 - Claudeワーカーを起動する
param([int]$Timeout = 30)
$ErrorActionPreference = "Stop"
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"
$pwsh = & $ctl status 2>$null
& $ctl start
Write-Host "RESULT: Claude worker is running"
