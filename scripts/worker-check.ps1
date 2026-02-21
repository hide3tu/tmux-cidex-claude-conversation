# worker-check.ps1 - Claudeワーカーの状態を確認する
$ErrorActionPreference = "Stop"
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"
& $ctl status
