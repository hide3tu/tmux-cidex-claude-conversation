# worker-send.ps1 - Claudeワーカーにテキストを送信する
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Text
)
$ErrorActionPreference = "Stop"
$ctl = Join-Path $PSScriptRoot "claude-ctl.ps1"
& $ctl send $Text
Write-Host "RESULT: Sent to Claude: $Text"
