#!/bin/bash
# Codex主体の自動開発スクリプト（並列ワーカー版）
#
# 使い方:
#   ./scripts/codex-main.sh
#
# 環境変数:
#   MAX_CLAUDE_WORKERS  — 並列Claudeワーカーの上限（デフォルト5、最大10）
#
# 前提条件:
#   - codex CLI がインストール済み
#   - claude CLI がインストール済み
#   - tmux がインストール済み
#   - AGENTS.md がプロジェクトルートにある

set -e
cd "$(dirname "$0")/.."

SESSION_NAME="codex-dev"
PROJECT_DIR="$(pwd)"

# 並列ワーカー上限（デフォルト5、最大10）
export MAX_CLAUDE_WORKERS="${MAX_CLAUDE_WORKERS:-5}"
if [ "$MAX_CLAUDE_WORKERS" -gt 10 ]; then
    MAX_CLAUDE_WORKERS=10
fi

# クリーンアップ関数
cleanup() {
    echo ""
    echo "終了処理中..."

    # 全ワーカーウィンドウを閉じる
    for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep '^claude-worker-'); do
        tmux kill-window -t "$SESSION_NAME:$w" 2>/dev/null || true
    done

    # レガシー単体ワーカーも閉じる
    tmux kill-window -t "$SESSION_NAME:claude-worker" 2>/dev/null || true

    # 全worktree削除
    if [ -d .worktrees ]; then
        for wt in .worktrees/worker-*; do
            [ -d "$wt" ] && git worktree remove "$wt" --force 2>/dev/null || true
        done
        rmdir .worktrees 2>/dev/null || true
    fi

    # シグナル・一時ファイル削除
    rm -f logs/.claude_done_* logs/.claude_done
    rm -f work/task-*.md work/review-*.md work/task.md work/review.md work/progress.md

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
echo "  並列ワーカー上限: $MAX_CLAUDE_WORKERS"
echo "  モデル: gpt-5.3-codex (reasoning: xhigh)"
echo "  --dangerously-bypass-approvals-and-sandbox: 全制限解除"
echo "  AGENTS.md は自動読込"
echo ""
echo "停止するには Ctrl+C を押してください"
echo ""

# Codexをエージェントモードで起動
codex -m gpt-5.3-codex -c model_reasoning_effort=xhigh --dangerously-bypass-approvals-and-sandbox "AGENTS.mdを読んで実行して"
