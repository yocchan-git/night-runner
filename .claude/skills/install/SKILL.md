---
name: install
description: night-runner を macOS の launchd に登録する。claude/node のパスを自動検出して PATH を焼き、plist を配備してロードする。「インストールして」「セットアップして」「夜間実行を有効にして」と言われたら使う。
---

# install — night-runner を夜間実行に載せる

ユーザーはファイル・ターミナル・plist を一切触らない。あなた（Claude）が裏で全部やる。

## 手順

1. リポジトリ root の `core/lib/install.sh` を実行する:
   ```
   bash core/lib/install.sh
   ```
   これが以下を自動で行う:
   - `claude` / `node` / `npx` の実パスを `which` で検出 → launchd 用 PATH を組む（launchd は PATH が極小なので必須）
   - `config/config.sh` を生成（マシン固有のパスをここに隔離。`.gitignore` 済み）
   - `core/runner.plist.template` を描画して `~/Library/LaunchAgents/com.<user>.night-runner.plist` に配備
   - `launchctl load` で登録

2. 出力を読み、`claude` が `NOT FOUND` だった場合はユーザーに「Claude Code CLI が見つからない」ことを伝え、インストール後に再実行する。

3. 成功したら、ユーザーに次の3点を**短く**伝える:
   - 夜間の実行時刻（既定 0:00）
   - 「今すぐ動作確認できます」→ test-now スキルを案内
   - 「あなたは何も触らなくていい」こと

## 注意（致命傷を防ぐ）

- 実行時刻を変えたい場合は `config/config.sh` の `NR_SCHEDULE_HOUR/MINUTE` を編集して **再度 install.sh を実行**（plist 再描画 + reload が必要）。
- macOS は sleep 中だと launchd が起きない。AC 電源 + 蓋開け、または `sudo pmset repeat wakeorpoweron ...` での事前 wake をユーザーに案内する（ただし sudo はユーザー自身に `! ...` で実行してもらう）。
