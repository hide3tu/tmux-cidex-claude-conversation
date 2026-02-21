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
echo "  --dangerously-bypass-approvals-and-sandbox: 全制限解除"
echo "  AGENTS.md は自動読込"
echo ""
echo "停止するには Ctrl+C を押してください"
echo ""

# Codexをエージェントモードで起動
# --dangerously-bypass-approvals-and-sandbox: サンドボックス+承認を全バイパス
# AGENTS.md はプロジェクトルートから自動読込される
codex --dangerously-bypass-approvals-and-sandbox "AGENTS.mdを読んで実行して"
