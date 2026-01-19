#!/bin/bash
# Codex主体の自動開発スクリプト
#
# 使い方:
#   ./scripts/codex-main.sh
#
# 前提条件:
#   - codex CLI がインストール済み
#   - tmux がインストール済み
#   - AGENTS.md がプロジェクトルートにある

set -e
cd "$(dirname "$0")/.."

SESSION_NAME="codex-dev"
PROJECT_DIR="$(pwd)"

# クリーンアップ関数
cleanup() {
    echo ""
    echo "終了処理中..."
    # claude-workerウィンドウがあれば閉じる
    tmux kill-window -t "$SESSION_NAME:claude-worker" 2>/dev/null || true
    echo "完了"
}
trap cleanup EXIT

# ディレクトリ準備
mkdir -p logs work

# tmuxセッション確認・作成
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "tmuxセッション '$SESSION_NAME' を作成します..."
    tmux new-session -d -s "$SESSION_NAME" -n "main" -c "$PROJECT_DIR"
fi

echo "Codexをエージェントモードで起動します..."
echo "  セッション: $SESSION_NAME"
echo "  --sandbox danger-full-access: サンドボックス無効"
echo "  --ask-for-approval never: 確認プロンプトなし"
echo "  AGENTS.md は自動読込"
echo ""
echo "停止するには Ctrl+C を押してください"
echo ""

# Codexをエージェントモードで起動
# --sandbox danger-full-access: サンドボックス無効
# --ask-for-approval never: 確認プロンプトなし
# AGENTS.md はプロジェクトルートから自動読込される
codex --sandbox danger-full-access --ask-for-approval never
