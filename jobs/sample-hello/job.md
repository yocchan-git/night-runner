---
name: sample-hello
enabled: false
schedule: nightly
---

# サンプル: 動作確認用の無害な job

> これは job.md の書き方を示すサンプル。`enabled: false` なので夜間には走らない。
> 実際に試すときは Claude に「sample-hello を有効にしてテストして」と頼む。

**仕様**:
runs/scratch/ ディレクトリを作り、その中に `hello-<date>.txt` を新規作成して、
1行「night-runner Phase 1 動作確認 OK (<現在時刻>)」と書き込む。

**既存パターン参照**:
特になし（独立した最小タスク）。

**迷ったら**:
ファイルが既にあれば上書きしてよい。日付は実行日のものを使う。

**禁止事項**:
- runs/scratch/ の外には一切書き込まない
- ネットワークアクセス・コマンド実行・git 操作はしない

**完了条件**:
runs/scratch/hello-<date>.txt が存在し、指定の1行が書かれていること。
