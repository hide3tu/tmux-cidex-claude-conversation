# tmux-codex-claude-conversation

Codex CLIをマネージャー、Claude CLIをワーカーとして連携させる自動開発フレームワーク。

## 概要

```
┌─────────────────────────────────────────────────────────┐
│  Codex (マネージャー)                                    │
│  - タスク選択・指示出し                                  │
│  - レビュー・進行管理                                    │
│  - docs/todo.md 更新                                    │
└────────────────┬────────────────────────────────────────┘
                 │ ファイル経由で通信
                 │ - work/task.md (指示)
                 │ - work/review.md (修正依頼)
                 │ - logs/.claude_done (完了シグナル)
                 ▼
┌─────────────────────────────────────────────────────────┐
│  Claude (ワーカー)                                       │
│  - Linux/macOS: tmux内で動作                             │
│  - Windows: ConPTYバックグラウンドプロセス内で動作         │
│  - 実装作業                                             │
│  - commit & push                                        │
│  - 完了シグナル送信                                      │
└─────────────────────────────────────────────────────────┘
```

## 実行環境

| | Mac / Linux | Windows |
|---|---|---|
| Claude制御 | tmux + send-keys（直接実行） | ConPTY + 名前付きパイプ (`claude-ctl.ps1`) |
| 起動スクリプト | `bash scripts/codex-main.sh` | `pwsh -File scripts/codex-main.ps1` |
| シグナル / タスク通信 | `logs/.claude_done`, `work/task.md` (共通) | 同左 |

## 前提条件

### 共通
- [Codex CLI](https://github.com/openai/codex) がインストール済み
- [Claude CLI](https://github.com/anthropics/claude-code) がインストール済み
- Git リポジトリとして初期化済み

### Mac / Linux
- tmux がインストール済み

### Windows
- Windows 10 1809以降（ConPTY対応）
- PowerShell 7+（pwsh）— `PWSH_PATH` 環境変数でパスを指定可能

## セットアップ

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

```
あなた: ユーザー認証機能を追加したい
Claude: いくつか確認させてください。認証方式は？（JWT / セッション / OAuth）
あなた: JWT
Claude: トークンの有効期限は？リフレッシュトークンは必要？
...
```

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
- 対象ファイルパスを明記させる

### 4. 自動実行

TODOが固まったら自動開発を開始:

**Linux/macOS:**
```bash
./scripts/codex-main.sh
```

**Windows:**
```powershell
pwsh -File scripts/codex-main.ps1
```

## 使い方

### 起動

**Linux/macOS:**
```bash
./scripts/codex-main.sh
```

これにより:
1. tmuxセッション `codex-dev` が作成される
2. Codexがエージェントモードで起動
3. `AGENTS.md` の指示に従い自動でタスクを処理開始

**Windows:**
```powershell
pwsh -File scripts/codex-main.ps1
```

これにより:
1. Codexがエージェントモードで起動
2. Claude CLIはConPTYバックグラウンドプロセスとして管理される
3. `AGENTS.md` の指示に従い自動でタスクを処理開始

### 停止

`Ctrl+C` で停止。Claudeのワーカープロセスは自動でクリーンアップされます。

## ファイル構成

```
.
├── AGENTS.md              # Codex（マネージャー）への指示書
├── CLAUDE.md              # Claude（ワーカー）への指示書
├── README.md              # このファイル
├── scripts/
│   ├── codex-main.sh      # 起動スクリプト（Mac/Linux）
│   ├── codex-main.ps1     # 起動スクリプト（Windows）
│   └── claude-ctl.ps1     # Claude制御ツール（Windows, ConPTY + 名前付きパイプ）
├── docs/
│   └── todo.md            # タスクリスト（要作成）
├── work/                  # 一時ファイル置き場（gitignore済み）
│   └── .gitkeep
└── logs/                  # シグナル・ログ用（gitignore済み）
    └── .gitkeep
```

## カスタマイズ

### タスク指示のフォーマット

Codexが `work/task.md` に書く指示のフォーマット:

```markdown
# タスク: [タスク名]

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

修正が必要な場合、Codexが `work/review.md` に書く内容:

```markdown
# レビュー指摘

## 問題点
- [問題1の説明]
- [問題2の説明]

## 修正方法
- [具体的な修正指示]
```

## トラブルシューティング

### Claudeが応答しない

30秒ごとにエンターキーが送信されますが、それでも応答がない場合:

**Linux/macOS:**
```bash
# 手動でClaudeウィンドウを確認
tmux attach -t codex-dev
# ウィンドウ切り替え: Ctrl+B, n
```

**Windows:**
```powershell
# Claude の状態を確認
pwsh -File scripts/claude-ctl.ps1 status

# 手動でEnterを送信
pwsh -File scripts/claude-ctl.ps1 enter
```

### タイムアウトが発生する

デフォルトのタイムアウトは60分。

- Linux/macOS: `AGENTS.md` の `timeout 3600` を調整
- Windows: `AGENTS.md` の `-Timeout 3600` を調整

### push が失敗する

Claudeは自動で `git pull --rebase && git push` を試みます。それでも失敗する場合は手動で解決が必要です。
