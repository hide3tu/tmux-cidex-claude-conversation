# tmux-codex-claude-conversation

Codex CLIをマネージャー、Claude CLI（複数）をワーカーとして連携させる並列自動開発フレームワーク。

## 概要

```
┌──────────────────────────────────────────────────────────────┐
│  Codex (マネージャー / gpt-5.3-codex xHigh)                  │
│  - タスク分析・ワーカー割当                                   │
│  - git worktree管理                                          │
│  - 並列監視・レビュー                                        │
│  - マージ・docs/todo.md 更新                                 │
└───────┬──────────┬──────────┬────────────────────────────────┘
        │          │          │  ファイル経由で通信
        │          │          │  - work/task-{i}.md (指示)
        │          │          │  - work/review-{i}.md (修正依頼)
        │          │          │  - logs/.claude_done_{i} (完了シグナル)
        ▼          ▼          ▼
┌────────────┐ ┌────────────┐ ┌────────────┐
│ Claude #1  │ │ Claude #2  │ │ Claude #N  │
│ worker-1   │ │ worker-2   │ │ worker-N   │
│ worktree/1 │ │ worktree/2 │ │ worktree/N │
│ branch:    │ │ branch:    │ │ branch:    │
│ task/1-xxx │ │ task/2-yyy │ │ task/N-zzz │
└────────────┘ └────────────┘ └────────────┘
```

### git worktreeによる並列化

複数のClaudeワーカーが同一リポジトリで別ブランチを同時に操作するため、**git worktree**で各ワーカーに独立した作業ディレクトリを割り当てます。

```bash
# ワーカーiの作業ディレクトリ作成
git worktree add .worktrees/worker-{i} -b task/{i}-{slug} main

# tmuxウィンドウはそのディレクトリで起動
tmux new-window -t codex-dev -n claude-worker-{i} -c "$(pwd)/.worktrees/worker-{i}"

# 完了後にworktree削除
git worktree remove .worktrees/worker-{i} --force
```

- 各worktreeは独立したワーキングディレクトリ（checkoutの競合なし）
- CLAUDE.mdはworktreeディレクトリにも自動で見える（gitが管理）
- `work/`, `logs/` はプロジェクトルートにあるので、Claudeにはフルパスで参照させる

## 前提条件

- [Codex CLI](https://github.com/openai/codex) がインストール済み
- [Claude CLI](https://github.com/anthropics/claude-code) がインストール済み
- Git リポジトリとして初期化済み
- tmux がインストール済み
- Mac / Linux 環境

## セットアップ

### 0. 実行環境の事前準備（重要）

自動開発を開始する前に、**各CLIのオンボーディングと認証を手動で完了**しておく必要があります。
これを済ませていない環境ではスクリプトによる自動制御が失敗します。

#### Claude CLI の初期設定

初回起動時に以下のプロンプトが順番に表示されます。**すべて手動で完了させてください**:

1. **テーマ選択** — 6つのテーマから選択
2. **ログイン** — ブラウザでOAuth認証（自動化不可）
3. **フォルダ信頼** — "Do you trust the files in this folder?" → Yesを選択
4. **bypass-permissions警告** — `--dangerously-skip-permissions` 使用時の警告 → "Yes, I accept"を選択

```bash
# 対象プロジェクトのディレクトリで一度手動起動する
cd your-project
claude --dangerously-skip-permissions

# 全プロンプトを手動で承認して、TUIが表示されたら /exit で終了

# 設定が保存されたか確認
cat ~/.claude/settings.json
# → "skipDangerousModePermissionPrompt": true があること

cat ~/.claude.json
# → "hasCompletedOnboarding": true があること
```

> **注意**: `--dangerously-skip-permissions` の警告ダイアログは、手動で一度承認するまで毎回表示されます（[既知の仕様](https://github.com/anthropics/claude-code/issues/25503)）。

#### リモート環境でのセットアップ

SSH先やCI環境など、ブラウザが使えない環境では、ローカルで認証済みの設定ファイルを事前配置します:

```bash
# ローカルで認証を完了した後、以下のファイルをリモートにコピー
scp ~/.claude.json remote:~/.claude.json
scp -r ~/.claude/settings.json remote:~/.claude/settings.json
```

必要なファイル:
- `~/.claude.json` — `"hasCompletedOnboarding": true` を含む
- `~/.claude/settings.json` — `"skipDangerousModePermissionPrompt": true` を含む

#### Codex CLI の確認

```bash
# Codexが正常に動作するか確認
codex --sandbox danger-full-access --ask-for-approval never "echo hello"
```

### 1. このリポジトリをテンプレートとして使用

```bash
# クローンまたはファイルをコピー
git clone https://github.com/hide3tu/tmux-cidex-claude-conversation.git your-project
cd your-project

# 新しいリモートに変更
git remote set-url origin <your-repo-url>
```

### 2. 必要なファイルを編集

#### `CLAUDE.md` の編集

プロジェクト固有の情報を記載:

```markdown
## プロジェクト概要

<!-- ここにプロジェクトの説明を書く -->
例: Webアプリケーション。React + TypeScript + Vite構成。

## 開発コマンド

```bash
npm install    # 依存関係インストール
npm run dev    # 開発サーバー起動
npm run build  # ビルド
npm test       # テスト実行
```

## 重要タスク

<!-- 現在のスプリントや優先タスクを記載 -->
- ユーザー認証機能の実装
- APIエンドポイントの追加
```

#### `docs/todo.md` の編集

タスクリストを記載（テンプレートが用意済み）:

```markdown
# TODOリスト

<!-- タスクの方針や背景があれば記載 -->

## 未完了タスク（優先度順）

- [ ] ユーザー認証APIの実装（`src/api/auth.ts`）
- [ ] ログイン画面のUI作成（`src/components/Login.tsx`）
- [ ] バリデーションロジックの追加（`src/utils/validation.ts`）

## 完了済み

<!-- 完了したタスクは [x] に変更してこちらへ移動 -->
```

### 3. .gitignore の設定

以下が `.gitignore` に含まれていることを確認:

```
# Codex-Claude連携用
work/task.md
work/review.md
work/progress.md
logs/.claude_done

# パラレルワーカー
work/task-*.md
work/review-*.md
logs/.claude_done_*

# git worktree作業ディレクトリ
.worktrees/
```

## 推奨ワークフロー（タスク作成編）

人間が直接TODOを書くと曖昧になりがち。以下の手順でAIにタスクを作らせると精度が上がる。

### 1. Claudeと壁打ち（実装プラン作成）

```bash
claude
```

Claude CLIを起動し、対話しながら実装プランを練る:

- 「このプロジェクトで○○を実現したい」と相談
- Claudeが質問してくるので答える（AskUserQuestionTool）
- 要件の曖昧な部分を潰していく
- 最終的に実装プランのドキュメントを出力させる

### 2. Codexでプロジェクト全体レビュー

```bash
codex
```

Codex CLIを起動し、実装プランとプロジェクト全体を読ませる:

- 「実装プランを読んで、既存コードとの整合性をレビューして」
- 既存アーキテクチャとの矛盾、不足している考慮点を洗い出させる
- プランを修正・補完

### 3. TODOリストの生成

Codexに具体的なタスクリストを生成させる:

- 「このプランを元に、docs/todo.md を作成して」
- 優先度順、依存関係を考慮した順序
- **対象ファイルパスを明記させる**（並列実行時のファイル重複判定に必要）

### 4. 自動実行

TODOが固まったら自動開発を開始:

```bash
# 並列ワーカー数を指定（オプション、デフォルト5）
export MAX_CLAUDE_WORKERS=3

./scripts/codex-main.sh
```

## 使い方

```bash
# デフォルト（最大5並列ワーカー）
./scripts/codex-main.sh

# ワーカー数を指定
MAX_CLAUDE_WORKERS=3 ./scripts/codex-main.sh
```

これにより:
1. tmuxセッション `codex-dev` が作成される
2. Codex (gpt-5.3-codex) がエージェントモードで起動
3. `AGENTS.md` の指示に従い、タスクを分析
4. 独立タスクごとにgit worktreeとClaudeワーカーを並列起動
5. 全ワーカー完了後、レビュー → mainにマージ → 次のバッチへ

### 停止

`Ctrl+C` で停止。全Claudeワーカーとworktreeは自動でクリーンアップされます。

### `MAX_CLAUDE_WORKERS` 環境変数

| 値 | 説明 |
|---|---|
| 1 | 逐次実行（並列なし） |
| 2〜5 | 推奨範囲 |
| 6〜10 | 大量の独立タスクがある場合 |
| デフォルト | 5 |

Codexはタスクの対象ファイルを分析し、ファイル重複がないタスクのみを同時実行します。
重複がある場合はバッチを分割して順次処理します。

## ファイル構成

```
.
├── AGENTS.md              # Codex（マネージャー）への指示書（並列版）
├── CLAUDE.md              # Claude（ワーカー）への指示書
├── README.md              # このファイル
├── scripts/
│   └── codex-main.sh      # 起動スクリプト（並列版）
├── docs/
│   └── todo.md            # タスクリスト（要作成）
├── work/                  # 一時ファイル置き場（gitignore済み）
│   └── .gitkeep
├── logs/                  # シグナル・ログ用（gitignore済み）
│   └── .gitkeep
└── .worktrees/            # git worktree作業ディレクトリ（gitignore済み、自動生成）
```

## カスタマイズ

### タスク指示のフォーマット

Codexが `work/task-{i}.md` に書く指示のフォーマット:

```markdown
# タスク: [タスク名]
# ワーカーID: {i}
# ブランチ: task/{i}-{slug} (checkout済み)
# シグナル: {PROJECT_ROOT}/logs/.claude_done_{i}
# レビューファイル: {PROJECT_ROOT}/work/review-{i}.md

## 概要
[何をするか]

## 対象ファイル
- path/to/file1.ts
- path/to/file2.tsx

## 要件
- [具体的な要件1]
- [具体的な要件2]

## 完了条件
- [完了の判断基準]
```

### レビューのフォーマット

修正が必要な場合、Codexが `work/review-{i}.md` に書く内容:

```markdown
# レビュー指摘（ワーカー{i}）

## 問題点
- [問題1の説明]
- [問題2の説明]

## 修正方法
- [具体的な修正指示]
```

## トラブルシューティング

### Claudeが応答しない

30秒ごとにエンターキーが送信されますが、それでも応答がない場合:

```bash
# 手動でClaudeウィンドウを確認
tmux attach -t codex-dev
# ウィンドウ切り替え: Ctrl+B, n
# ウィンドウ一覧: Ctrl+B, w
```

### worktreeが残る

異常終了時にworktreeが残った場合:

```bash
# 残っているworktreeを確認
git worktree list

# 手動削除
git worktree remove .worktrees/worker-1 --force
# または全削除
rm -rf .worktrees && git worktree prune
```

### タイムアウトが発生する

デフォルトのタイムアウトは60分。`AGENTS.md` の `TIMEOUT=3600` を調整。

### push が失敗する

Claudeは自動で `git pull --rebase && git push -u origin HEAD` を試みます。それでも失敗する場合は手動で解決が必要です。

### マージコンフリクト

並列ワーカーのブランチがコンフリクトした場合、Codexは自動で `merge --abort` してスキップします。
スキップされたタスクは `docs/todo.md` に記録されるので、次のバッチで再実行されます。
