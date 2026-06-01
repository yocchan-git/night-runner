# runs/ — 実行結果

夜間 / 即時テストの実行結果がここに溜まる（`.gitignore` 済み。ローカルの記録）。

| ファイル | 中身 |
|---|---|
| `<date>-summary.md` | その日の実行サマリー。**ランチャ（runner.sh）が終端で書く**。契約フィールドを含む |
| `<date>.log` | runner の詳細ログ（`runner start` 行の数 = 強制ループのセッション数） |
| `state/<date>/<job>.done` | **per-job 完了マーカー**。進捗のグラウンドトゥルース。再着手防止に使う |
| `launchd.out.log` / `launchd.err.log` | launchd が捕捉した標準出力 / エラー（PATH 問題の一次情報） |

## 進捗判定の仕組み（Phase 2）

進捗の真実源は **per-job 完了マーカー**（`state/<date>/<job>.done`）。
orchestrator（claude）は job を確定するたびに、次の job に移る前にマーカーを書く。
ランチャはマーカー数を `started` として数え、強制ループを判断する:

- `started < planned` かつ `iteration < N` → 新規セッションで `exec` 再起動
- 新規セッションはマーカーのある job を**スキップ**（再着手しない）
- `started == planned` → `completed_all`
- 上限 N に達してなお未完 → `aborted_max_iterations`（無限ループ回避）

claude には summary を書かせない（ヘッドレスで形式が不安定なため）。
claude の責務は「実行 → 実在確認 → マーカー記入」だけ。

## summary.md の契約フィールド

```
**total_tasks_planned**: N   # enabled な job 総数
**total_tasks_started**:  M   # 完了マーカーのある job 数（確定状態に至った数）
**iteration**: K              # 強制ループの周回数（0 始まり）
**status**: completed_all | aborted_max_iterations | aborted_by_errors
```

末尾の `_RUN COMPLETE_` センチネルはランチャが**終端でのみ**書く
（中間の周回では書かない）。test-now はこれを真の完了検出に使う。
