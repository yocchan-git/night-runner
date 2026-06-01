---
name: test-now
description: 夜を待たず、登録済みの夜間実行を「今すぐ」launchd 経由で1回走らせて結果を見せる。「今すぐテストして」「動作確認して」「試しに走らせて」と言われたら使う。Phase 0 以降の各 Phase の動作確認はこれで行う。
---

# test-now — 即時テスト実行

夜間実行（launchd ジョブ）を、本番と同一の launchd 環境で今すぐ1回発火させ、
結果（summary とログ）をユーザーに見せる。昼に検証を回すための口。

## 手順

1. `core/lib/test_now.sh` を実行する:
   ```
   bash core/lib/test_now.sh
   ```
   これが `launchctl start <label>` でジョブを即時発火し、`runs/<date>-summary.md` に
   完了センチネル（`_RUN COMPLETE_`）が書かれるまで待ってから summary とログ末尾を出力する。

   - 完了に時間がかかる想定なら引数でタイムアウト秒を渡す: `bash core/lib/test_now.sh 600`

2. 出力された summary をユーザーに**要約して**見せる。特に:
   - `status`（completed_all など）
   - `total_tasks_planned` / `total_tasks_started`（Phase 2 以降の完走判定の材料）
   - 環境チェック（claude/node が解決できているか）

3. ズレや失敗があれば、何が起きたかを率直に伝える。`runs/<date>.log` と
   `runs/launchd.err.log` が一次情報。推測で「動いた」と言わない。

## 設計メモ

- 時刻書換ではなく `launchctl start` を使う。StartCalendarInterval を一切汚さず、
  本番と同じ EnvironmentVariables（PATH 等）でジョブを発火できるため。
  「終わったら時刻を元に戻す」工程が不要になり、より安全。
