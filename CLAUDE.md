# CLAUDE.md

このファイルはClaude Codeへの指示書です。

## プロジェクト概要

<!-- ここにプロジェクトの概要を記載 -->

## 開発コマンド

<!-- ここにプロジェクト固有の開発コマンドを記載 -->
```bash
# 例:
# pnpm install
# pnpm build
# pnpm test
```

## 重要タスク

<!-- ここに現在取り組むべきタスクを記載 -->

## 自動開発モード（Codex連携時）

このプロジェクトではCodexと連携した自動開発を行う場合があります。
並列ワーカーとして起動される場合、以下のパラメータが指示メッセージで渡されます:

- **ワーカーID**: `{i}` — 自分の番号
- **タスクファイル**: `work/task-{i}.md` — プロジェクトルートからの相対パス
- **シグナルファイル**: `logs/.claude_done_{i}` — プロジェクトルートからの相対パス
- **レビューファイル**: `work/review-{i}.md` — プロジェクトルートからの相対パス
- **ブランチ**: `task/{i}-{slug}` — checkout済み
- **プロジェクトルート**: 指示メッセージで絶対パスが伝えられる

### 作業フロー

1. 起動直後に前回のシグナルを消す
2. プロジェクトルートの`work/task-{i}.md`を読んでタスクを理解する
3. `PROJECT_ROOT/.worktrees/worker-{i}` へ移動し、`task/{i}-{slug}` にいることを確認する
4. 実装を行う（worktreeディレクトリ内で作業）
5. **実装完了後、自分でcommit + pushする**（下記参照）
6. 完了シグナルを送信してCodexに通知
7. 修正指示があればプロジェクトルートの`work/review-{i}.md`を読んで対応 → 修正後また commit + push → シグナル

### 作業開始前の必須ガード

実装前に必ず以下を実行し、失敗時はコード変更を開始しない:

```bash
cd {PROJECT_ROOT}/.worktrees/worker-{i} || exit 1
git checkout task/{i}-{slug} || exit 1
pwd
git branch --show-current
```

期待値:
- `pwd` が `{PROJECT_ROOT}/.worktrees/worker-{i}`
- `git branch --show-current` が `task/{i}-{slug}`

期待値と一致しない場合は、実装せずにCodexからの再指示を待つ。

### commit + push の手順

実装が完了したら、以下を実行:

```bash
git add -A
git commit -m "feat: [タスク名の要約]"
git push -u origin HEAD
rm -f {PROJECT_ROOT}/work/progress.md
touch {PROJECT_ROOT}/logs/.claude_done_{i}
```

**注意:**
- コミットメッセージは `feat:`, `fix:`, `refactor:` などの接頭辞を使う
- `work/task-{i}.md`, `work/review-{i}.md` はコミットしない（`.gitignore`済み）
- pushは `git push -u origin HEAD` を使う（ブランチ名をハードコードしない）
- **mainブランチに直接pushしない** — 必ずタスクブランチにpushする
- pushが失敗したら `git pull --rebase && git push -u origin HEAD` を試す
- **変更がない場合**（既に実装済み等）でも、必ず完了シグナルを送信してCodexに通知する
- シグナルファイルのパスはプロジェクトルートからの絶対パスで指定される

### 想定外の差分が出た場合

タスクファイルの対象外ファイルに変更が出たら、**確認せずに破棄して続行**する。

破棄方法（対象外ファイルのみ）:
```bash
git restore --source=HEAD --worktree --staged -- <file>
```

### 自動継続ルール

- **選択肢を提示しない**: 「Next steps」「pick any」などの選択肢を出さない。自分で判断して進める
- **テストはスキップ可**: 手動確認が必要なテストはスキップしてよい
- **重大エラー時は実装を開始しない**: `worktree未存在` / `CWD不一致` / `ブランチ不一致` は復旧まで停止。軽微なノイズのみ無視可
- **必ず完了シグナルで終わる**: 作業終了時は必ず完了シグナル（`logs/.claude_done_{i}`ファイル作成）を送信。これを忘れるとCodexが永遠に待つ
- **実行方式の確認で止まらない**: 「この環境では動かない」「直接tmuxで起動します」などの説明だけを出して停止しない。必要な方式へ即切り替えて処理継続する

### 読んではいけないファイル

コンテキスト節約のため、以下は読まない:
- `logs/`内のファイル（シグナル以外）
- `work/`内の過去のファイル（現在のタスク以外）
- 他のワーカーのタスクファイルやレビューファイル
