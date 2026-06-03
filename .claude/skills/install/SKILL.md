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

3. 成功したら、ユーザーに次を**短く**伝える:
   - 夜間の実行時刻（既定 0:00）
   - 「今すぐ動作確認できます」→ test-now スキルを案内
   - 「あなたは何も触らなくていい」こと

4. **セットアップ時の注意点を必ず提示して、ユーザーに確認する**（ここを省略しない）:

   **(a) スリープ防止（夜間に確実に走らせるための前提）**
   launchd はスリープ中の Mac を起こさない。夜間にスリープしていると job が走らない。
   次のどちらかが要る、と伝える:
   - 電源接続＋蓋開けで AC 自動スリープ無効化: `sudo pmset -c sleep 0`
   - もしくは実行前に自動起床: `sudo pmset repeat wakeorpoweron MTWRFSU 23:55:00`

   `sudo` が要るので**ユーザー自身に実行してもらう**（`! sudo pmset ...` を案内）。
   「今その設定をしますか？コマンドを出しましょうか？」と**聞く**。

   **(b) ノートPCの持ち運び注意（軽くでよいが必ず触れる）**
   「重いタスク処理中にノートPCを折りたたんで持ち運ぶと、排熱できず高温になり危険な
   ことがあります。job 実行中は蓋を閉じて移動しないでください」と一言伝える。

## 注意（致命傷を防ぐ）

- 実行時刻を変えたい場合は `config/config.sh` の `NR_SCHEDULE_HOUR/MINUTE` を編集して **再度 install.sh を実行**（plist 再描画 + reload が必要）。
- スリープ防止・持ち運び注意は上記ステップ4で必ずユーザーに提示する。sudo はユーザー自身に `! ...` で実行してもらう。
