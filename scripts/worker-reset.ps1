# worker-reset.ps1 - シグナルファイルをクリアする
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$doneFile = Join-Path $projectRoot "logs\.claude_done"
if (Test-Path $doneFile) {
    Remove-Item $doneFile -Force
}
Write-Host "RESULT: Signal cleared"
