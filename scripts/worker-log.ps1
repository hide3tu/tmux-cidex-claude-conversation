# worker-log.ps1 - ConPTYログを表示する
$ErrorActionPreference = "Stop"
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"
& $ctl log
