#!/bin/bash
# Codex主体の自動開発スクリプト（並列ワーカー版）
#
# 使い方:
#   ./scripts/codex-main.sh
#
# 環境変数:
#   MAX_CLAUDE_WORKERS  — 並列Claudeワーカーの上限（デフォルト5、最大10）
#   CODEX_TIMEOUT_SECONDS — codex本体のハードタイムアウト秒（0で無効、デフォルト7200）
#   CODEX_RUN_MODE       — codex起動モード（exec|interactive、デフォルトexec）
#   CODEX_EPHEMERAL      — exec起動で --ephemeral を使うか（1/0、デフォルト1）
#   CODEX_MAX_CYCLES     — codex実行サイクル上限（デフォルト8）
#   CODEX_NO_PROGRESS_LIMIT — 未完了件数が減らない連続回数で停止（デフォルト2）
#   AI_STOP_JUDGE_ENABLED — 停止判定にHaikuを使うか（1/0、デフォルト1）
#   AI_STOP_JUDGE_MODEL — 停止判定で使うClaudeモデル（デフォルトclaude-haiku-4-5）
#   AI_STOP_JUDGE_FALLBACK_MODEL — AI判定モデルのフォールバック（デフォルトhaiku）
#   AI_STOP_JUDGE_MAX_CONTINUES — AI判定で継続できる最大回数（デフォルト2）
#   AI_STOP_JUDGE_TIMEOUT_SECONDS — AI判定タイムアウト秒（timeout/gtimeoutがあれば適用）
#   CODEX_MODEL              — codexで使うモデル（デフォルトgpt-5.3-codex）
#   CODEX_REASONING_EFFORT   — 推論effort（デフォルトxhigh）
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

# codex本体のハードタイムアウト（デフォルト2時間）
CODEX_TIMEOUT_SECONDS="${CODEX_TIMEOUT_SECONDS:-7200}"

# codex起動モード（デフォルトは非TTYでも動くexec）
CODEX_RUN_MODE="${CODEX_RUN_MODE:-exec}"

# exec起動時のstate汚染を避けるため、デフォルトでephemeralを有効化
CODEX_EPHEMERAL="${CODEX_EPHEMERAL:-1}"

# codex実行サイクル上限（デフォルト8）
CODEX_MAX_CYCLES="${CODEX_MAX_CYCLES:-8}"

# 未完了件数が減らない連続回数で停止（デフォルト2）
CODEX_NO_PROGRESS_LIMIT="${CODEX_NO_PROGRESS_LIMIT:-2}"

# 停止判定にHaikuを使うか（デフォルト有効）
AI_STOP_JUDGE_ENABLED="${AI_STOP_JUDGE_ENABLED:-1}"

# 停止判定に使うモデル（デフォルトHaiku 4.5）
AI_STOP_JUDGE_MODEL="${AI_STOP_JUDGE_MODEL:-claude-haiku-4-5}"

# AI判定モデルのフォールバック（CLI側でモデル未対応時）
AI_STOP_JUDGE_FALLBACK_MODEL="${AI_STOP_JUDGE_FALLBACK_MODEL:-haiku}"

# AI判定による継続の上限（デフォルト2）
AI_STOP_JUDGE_MAX_CONTINUES="${AI_STOP_JUDGE_MAX_CONTINUES:-2}"

# AI判定のタイムアウト秒（timeout/gtimeoutがある場合のみ適用）
AI_STOP_JUDGE_TIMEOUT_SECONDS="${AI_STOP_JUDGE_TIMEOUT_SECONDS:-90}"

# codexモデル設定
CODEX_MODEL="${CODEX_MODEL:-gpt-5.3-codex}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"

# 親Codex環境からの引き継ぎで子プロセスが誤動作しないようにクリアする
CODEX_CLEAN_ENV=(env -u CODEX_THREAD_ID -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_CI)

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

count_open_tasks() {
    if command -v rg >/dev/null 2>&1; then
        rg -n '^- \[ \]' docs/todo.md 2>/dev/null | wc -l | tr -d ' '
    else
        grep -n '^- \[ \]' docs/todo.md 2>/dev/null | wc -l | tr -d ' '
    fi
}

show_open_tasks() {
    if command -v rg >/dev/null 2>&1; then
        rg -n '^- \[ \]' docs/todo.md 2>/dev/null || true
    else
        grep -n '^- \[ \]' docs/todo.md 2>/dev/null || true
    fi
}

write_stop_report() {
    local reason="$1"
    local open_count="$2"
    {
        echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "reason: ${reason}"
        echo "open_tasks: ${open_count}"
        echo "last_exit_code: ${LAST_EXIT:-0}"
        echo "open_task_lines:"
        show_open_tasks
    } > logs/codex-stop-reason.txt
}

log_ai_judge() {
    local reason="$1"
    local decision="$2"
    local model="$3"
    local output="$4"
    {
        echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "reason: ${reason}"
        echo "decision: ${decision}"
        echo "model: ${model}"
        echo "output_begin"
        printf '%s\n' "$output"
        echo "output_end"
        echo "---"
    } >> logs/codex-ai-judge.log
}

run_with_optional_timeout() {
    local timeout_sec="$1"
    shift
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${timeout_sec}" "$@"
        return $?
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_sec}" "$@"
        return $?
    fi
    "$@"
}

ai_should_continue() {
    local reason="$1"
    local open_count="$2"
    local decision=""
    local output=""
    local prompt=""
    local status=0
    local model_used="$AI_STOP_JUDGE_MODEL"

    if [ "$AI_STOP_JUDGE_ENABLED" != "1" ]; then
        echo "[AI-JUDGE] disabled"
        return 1
    fi

    if [ "$AI_CONTINUE_USED" -ge "$AI_STOP_JUDGE_MAX_CONTINUES" ]; then
        echo "[AI-JUDGE] 継続上限(${AI_STOP_JUDGE_MAX_CONTINUES})に到達"
        return 1
    fi

    if ! command -v claude >/dev/null 2>&1; then
        echo "[AI-JUDGE] claude CLIがないため停止"
        return 1
    fi

    prompt=$(cat <<EOF
あなたは実行制御の審査役です。以下の停止候補を見て、再実行する価値があるかを判定してください。

[停止候補]
- reason: ${reason}
- open_tasks: ${open_count}
- last_exit_code: ${LAST_EXIT}
- cycle: ${CYCLE}
- max_cycles: ${CODEX_MAX_CYCLES}
- no_progress_count: ${NO_PROGRESS}
- no_progress_limit: ${CODEX_NO_PROGRESS_LIMIT}

[判定ルール]
- reason が MANUAL_INTERRUPT の場合は必ず STOP
- 同じ原因で改善見込みが低い場合は STOP
- 一時的失敗の可能性があり、次サイクルで改善見込みがある場合のみ CONTINUE

出力は必ず次の2行のみ:
DECISION: CONTINUE または STOP
REASON: 20文字以内で簡潔に
EOF
)

    if output="$(run_with_optional_timeout "$AI_STOP_JUDGE_TIMEOUT_SECONDS" claude -p --dangerously-skip-permissions --model "$model_used" "$prompt" 2>&1)"; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ] && [ -n "$AI_STOP_JUDGE_FALLBACK_MODEL" ] && [ "$AI_STOP_JUDGE_FALLBACK_MODEL" != "$model_used" ]; then
        local fallback_output=""
        if fallback_output="$(run_with_optional_timeout "$AI_STOP_JUDGE_TIMEOUT_SECONDS" claude -p --dangerously-skip-permissions --model "$AI_STOP_JUDGE_FALLBACK_MODEL" "$prompt" 2>&1)"; then
            model_used="$AI_STOP_JUDGE_FALLBACK_MODEL"
            output="$fallback_output"
            status=0
            echo "[AI-JUDGE] model fallback: ${AI_STOP_JUDGE_MODEL} -> ${model_used}"
        fi
    fi

    if [ "$status" -ne 0 ]; then
        log_ai_judge "$reason" "STOP" "$model_used" "judge_failed(status=$status): $output"
        echo "[AI-JUDGE] 失敗(status=${status})のため停止"
        return 1
    fi

    if printf '%s\n' "$output" | grep -Eiq '^DECISION:[[:space:]]*CONTINUE'; then
        decision="CONTINUE"
    elif printf '%s\n' "$output" | grep -Eiq '^DECISION:[[:space:]]*STOP'; then
        decision="STOP"
    else
        decision="STOP"
    fi

    log_ai_judge "$reason" "$decision" "$model_used" "$output"

    if [ "$decision" = "CONTINUE" ]; then
        AI_CONTINUE_USED=$((AI_CONTINUE_USED + 1))
        echo "[AI-JUDGE] CONTINUE (${AI_CONTINUE_USED}/${AI_STOP_JUDGE_MAX_CONTINUES})"
        return 0
    fi

    echo "[AI-JUDGE] STOP"
    return 1
}

on_interrupt() {
    echo ""
    echo "[STOP] ユーザー中断を検知しました"
    OPEN_NOW="$(count_open_tasks)"
    write_stop_report "MANUAL_INTERRUPT" "$OPEN_NOW"
    exit 130
}

trap on_interrupt INT TERM

# ディレクトリ準備
mkdir -p logs work
rm -f logs/codex-stop-reason.txt
rm -f logs/codex-ai-judge.log

# tmuxセッション確認・作成
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "tmuxセッション '$SESSION_NAME' を作成します..."
    tmux new-session -d -s "$SESSION_NAME" -n "main" -c "$PROJECT_DIR"
fi

echo "Codexをエージェントモードで起動します..."
echo "  セッション: $SESSION_NAME"
echo "  並列ワーカー上限: $MAX_CLAUDE_WORKERS"
echo "  codexハードタイムアウト秒: $CODEX_TIMEOUT_SECONDS (0=無効)"
echo "  codex起動モード: $CODEX_RUN_MODE"
echo "  codex ephemeral: $CODEX_EPHEMERAL"
echo "  codex最大サイクル: $CODEX_MAX_CYCLES"
echo "  進捗停滞許容回数: $CODEX_NO_PROGRESS_LIMIT"
echo "  AI停止判定: $AI_STOP_JUDGE_ENABLED (model=$AI_STOP_JUDGE_MODEL, fallback=$AI_STOP_JUDGE_FALLBACK_MODEL, max_continues=$AI_STOP_JUDGE_MAX_CONTINUES)"
echo "  モデル: $CODEX_MODEL (reasoning: $CODEX_REASONING_EFFORT)"
echo "  --dangerously-bypass-approvals-and-sandbox: 全制限解除"
echo "  AGENTS.md は自動読込"
echo ""
echo "停止するには Ctrl+C を押してください"
echo ""

# Codex起動コマンド構築
if [ "$CODEX_RUN_MODE" = "interactive" ] && [ -t 0 ] && [ -t 1 ]; then
    CODEX_CMD=("${CODEX_CLEAN_ENV[@]}" codex -m "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING_EFFORT" --dangerously-bypass-approvals-and-sandbox "AGENTS.mdを読んで実行して")
else
    if [ "$CODEX_EPHEMERAL" = "1" ]; then
        CODEX_CMD=("${CODEX_CLEAN_ENV[@]}" codex exec --ephemeral -m "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING_EFFORT" --dangerously-bypass-approvals-and-sandbox "AGENTS.mdを読んで実行して")
    else
        CODEX_CMD=("${CODEX_CLEAN_ENV[@]}" codex exec -m "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING_EFFORT" --dangerously-bypass-approvals-and-sandbox "AGENTS.mdを読んで実行して")
    fi
fi

# Codexをエージェントモードで起動
run_codex_once() {
    if [ "$CODEX_TIMEOUT_SECONDS" -gt 0 ]; then
        "${CODEX_CMD[@]}" &
        CODEX_PID=$!

        (
            sleep "$CODEX_TIMEOUT_SECONDS"
            if kill -0 "$CODEX_PID" 2>/dev/null; then
                echo ""
                echo "[TIMEOUT] codex実行が${CODEX_TIMEOUT_SECONDS}秒を超えたため停止します"
                kill -TERM "$CODEX_PID" 2>/dev/null || true
                sleep 5
                kill -KILL "$CODEX_PID" 2>/dev/null || true
            fi
        ) &
        WATCHDOG_PID=$!

        wait "$CODEX_PID"
        EXIT_CODE=$?
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        return "$EXIT_CODE"
    fi

    "${CODEX_CMD[@]}"
}

OPEN_BEFORE="$(count_open_tasks)"
PREV_OPEN="$OPEN_BEFORE"
OPEN_NOW="$OPEN_BEFORE"
NO_PROGRESS=0
CYCLE=1
LAST_EXIT=0
STOP_REASON=""
AI_CONTINUE_USED=0

echo "未完了タスク数(開始時): $OPEN_BEFORE"

while true; do
    if [ "$CYCLE" -gt "$CODEX_MAX_CYCLES" ]; then
        STOP_REASON="MAX_CYCLES_REACHED"
        echo "[STOP] 最大サイクル(${CODEX_MAX_CYCLES})に到達"
        if ai_should_continue "$STOP_REASON" "$OPEN_NOW"; then
            CODEX_MAX_CYCLES=$((CODEX_MAX_CYCLES + 1))
            echo "[AI-JUDGE] サイクル上限を ${CODEX_MAX_CYCLES} に拡張して続行"
            continue
        fi
        break
    fi

    echo ""
    echo "[RUN] codex cycle ${CYCLE}/${CODEX_MAX_CYCLES}"

    if run_codex_once; then
        LAST_EXIT=0
    else
        LAST_EXIT=$?
    fi

    OPEN_NOW="$(count_open_tasks)"
    echo "[RUN] cycle ${CYCLE} 終了: exit=${LAST_EXIT}, 未完了=${OPEN_NOW}"

    if [ "$OPEN_NOW" -eq 0 ]; then
        rm -f logs/codex-stop-reason.txt
        echo "[DONE] docs/todo.md の未完了タスクは0件です"
        exit 0
    fi

    if [ "$OPEN_NOW" -lt "$PREV_OPEN" ]; then
        NO_PROGRESS=0
    else
        NO_PROGRESS=$((NO_PROGRESS + 1))
    fi

    if [ "$NO_PROGRESS" -ge "$CODEX_NO_PROGRESS_LIMIT" ]; then
        STOP_REASON="NO_PROGRESS"
        echo "[STOP] 未完了タスク数が減らない状態が${NO_PROGRESS}回続いたため停止します"
        if ai_should_continue "$STOP_REASON" "$OPEN_NOW"; then
            NO_PROGRESS=0
            PREV_OPEN=$((OPEN_NOW + 1))
            CYCLE=$((CYCLE + 1))
            continue
        fi
        break
    fi

    PREV_OPEN="$OPEN_NOW"
    CYCLE=$((CYCLE + 1))
done

if [ -z "$STOP_REASON" ]; then
    if [ "$LAST_EXIT" -ne 0 ]; then
        STOP_REASON="CODEX_EXIT_NONZERO"
    else
        STOP_REASON="UNKNOWN"
    fi
fi

echo "[STOP-REASON] ${STOP_REASON} (last_exit=${LAST_EXIT}, open_tasks=${OPEN_NOW})"
write_stop_report "$STOP_REASON" "$OPEN_NOW"
echo "[STOP-REPORT] logs/codex-stop-reason.txt"
echo "[WARN] 未完了タスクが残っています:"
show_open_tasks
exit 2
