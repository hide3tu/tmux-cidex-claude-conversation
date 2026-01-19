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

### 作業フロー

1. 起動直後に `rm -f logs/.claude_done` を実行して前回のシグナルを消す
2. `work/task.md`を読んでタスクを理解する
3. 実装を行う
4. **実装完了後、自分でcommit + pushする**（下記参照）
5. `touch logs/.claude_done` を実行してCodexに通知
6. 修正指示があれば`work/review.md`を読んで対応 → 修正後また commit + push → シグナル

### commit + push の手順

実装が完了したら、以下を実行:
```bash
git add -A
git commit -m "feat: [タスク名の要約]"
git push
rm -f work/progress.md
touch logs/.claude_done
```

**注意:**
- コミットメッセージは `feat:`, `fix:`, `refactor:` などの接頭辞を使う
- `work/task.md`, `work/review.md`, `work/progress.md` はコミットしない（`.gitignore`済み）
- **`work/progress.md` は必ず削除する**（残るとコンテキストが重くなる）
- pushが失敗したら `git pull --rebase && git push` を試す
- **変更がない場合**（既に実装済み等）でも、必ず `touch logs/.claude_done` を実行してCodexに通知する

### 想定外の差分が出た場合

`work/task.md`の対象外ファイルに変更が出たら、**確認せずに破棄して続行**する。

破棄方法（対象外ファイルのみ）:
```bash
git restore --source=HEAD --worktree --staged -- <file>
```

### 自動継続ルール

- **選択肢を提示しない**: 「Next steps」「pick any」などの選択肢を出さない。自分で判断して進める
- **テストはスキップ可**: 手動確認が必要なテストはスキップしてよい
- **エラーがあっても進む**: パースエラー等があっても、commit + push + シグナル送信を実行
- **必ず完了シグナルで終わる**: 作業終了時は必ず `touch logs/.claude_done` を実行。これを忘れるとCodexが永遠に待つ

### 読んではいけないファイル

コンテキスト節約のため、以下は読まない:
- `logs/`内のファイル（シグナル以外）
- `work/`内の過去のファイル（現在のタスク以外）
