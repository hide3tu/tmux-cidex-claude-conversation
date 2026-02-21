# codex-main.ps1 - Codex自動開発エントリポイント (Windows版)
#
# 使い方:
#   pwsh -File scripts/codex-main.ps1
#
# 前提条件:
#   - codex CLI がインストール済み
#   - claude CLI がインストール済み
#   - PowerShell 7+ (pwsh)
#   - Windows 10 1809+
#   - AGENTS.md がプロジェクトルートにある

$ErrorActionPreference = "Stop"

# プロジェクトルートに移動
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

$claudeCtl = Join-Path $PSScriptRoot "claude-ctl.ps1"

# ディレクトリ準備
New-Item -ItemType Directory -Path "logs", "work" -Force | Out-Null

Write-Host "Codexをエージェントモードで起動します..."
Write-Host "  --sandbox danger-full-access: サンドボックス無効"
Write-Host "  --ask-for-approval never: 確認プロンプトなし"
Write-Host "  AGENTS.md は自動読込"
Write-Host ""
Write-Host "停止するには Ctrl+C を押してください"
Write-Host ""

try {
    codex --sandbox danger-full-access --ask-for-approval never "AGENTS.mdを読んで実行して"
}
finally {
    Write-Host ""
    Write-Host "終了処理中..."
    & $claudeCtl kill 2>$null
    Write-Host "完了"
}
