# worker-3 誤書き込みの原因と再発防止

## 原因

- `git worktree add` 失敗時に、該当workerの起動を止めずに進んだ
- `tmux new-window -c <worktree>` の `<worktree>` が存在しない場合、別ディレクトリでpaneが起動した
- 起動後に `pane_current_path` / ブランチの検証がなかった
- 結果として、workerがworktree外（main/ルート）に書き込んだ

## 再発防止（実装済み）

- `AGENTS.md`:
  - `git worktree add` / `tmux new-window` / CWD不一致 / ブランチ不一致を重大エラー化
  - ステップ3.5に「起動前プリフライト（ACTIVE_WORKERS確定）」を追加
  - `tmux new-window` 後に `pane_current_path` を必須検証
  - 失敗workerは起動せず、タスクを再キュー
  - 監視ループは `ACTIVE_WORKERS` のみ対象
- `CLAUDE.md`:
  - 実装前に `cd {PROJECT_ROOT}/.worktrees/worker-{i}` と `git checkout task/{i}-{slug}` を必須化
  - `pwd` / `git branch --show-current` が期待値と不一致なら実装開始禁止

## 運用チェックリスト

起動直前:

```bash
git worktree list
```

起動後（各worker）:

```bash
tmux display-message -p -t codex-dev:claude-worker-{i} '#{pane_current_path}'
```

監視中:

- `logs/.claude_done_{i}` だけで完了判定しない
- CWD不一致を検知したら即 `tmux kill-window` + 再キュー

