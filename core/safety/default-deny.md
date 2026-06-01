# デフォルト安全境界（default deny list）

night-runner が**ユーザー設定ゼロでも**守る最低限の境界。`--dangerously-skip-permissions`
で走る夜間実行において、OS の承認プロンプトの代わりにコア側で担保する。

## どこで止めているか（重要）

プロンプトの「お願い」ではない。**Claude Code の PreToolUse フック**（`core/safety/guard.py`、
`.claude/settings.json` で登録）が、ツール実行の**直前にランタイム側で**判定して deny する。
`--dangerously-skip-permissions` 下でもフックは発火し deny が効くことを実機検証済み。
→ プロンプトインジェクションでプロンプト指示が無視されても、この層は無効化されない。
claude（モデル）が従うかどうかに依存しない。

## 止める対象（4カテゴリ「だけ」）

誰の環境でも致命傷になるものに絞る。これ以外は止めない（完走性を殺さない）。

1. **破壊的削除**: 作業ディレクトリ外への `rm -rf`／`dd of=/dev/...`／`mkfs`／
   `diskutil erase`／`shred`／デバイス直書き／フォークボム。
   作業ディレクトリ内の削除は止めない。
2. **課金が発生する操作**: クラウドのプロビジョニング/デプロイ
   （`gcloud/aws/az ... create|deploy`、`terraform apply` 等）。
3. **本番への push / deploy / 不可逆な外部送信**: `git push`（強制含む）、`gh pr merge`、
   `gh release`、`npm/yarn/pnpm publish`、`firebase/vercel/netlify/serverless/fly/eb/heroku deploy`、
   `kubectl` 変更、`docker push`、MCP の `merge_pull_request`/`push_files`/`create_or_update_file` 等。
4. **認証情報・秘密情報の外部送信**: ネットワーク送信コマンド（curl/wget/scp/nc 等）＋
   秘密参照（`.env`/`.ssh`/`id_rsa`/`credentials`/`token` 等）の同時出現、Keychain 取り出し、
   秘密を含む WebFetch。

## 止めないもの

- 作業ディレクトリ内のファイル作成・編集・削除
- ローカルのテスト・ビルド・lint
- `git add` / `git commit` / ブランチ作成（**push しなければ**ローカルで可逆）
- 上記4カテゴリに当たらない通常のコマンド

> libe ドメイン固有（DB スキーマ変更等）は**入れない**。プロジェクト固有の追加停止条件は
> `config/config.sh` の `NR_EXTRA_DENY_FILE` で拡張する想定（コアは触らない）。

## ブロックされた時の挙動（非対称設計 / 資料 3-4）

バッチ全体は止めない。**そのタスクだけ `safety_blocked` で記録して次へ進む**。
deny は `runs/safety.log` に記録される。朝、人間が safety_blocked を裁く。
