# runs/ — 実行結果

夜間 / 即時テストの実行結果がここに溜まる（`.gitignore` 済み。ローカルの記録）。

| ファイル | 中身 |
|---|---|
| `<date>-summary.md` | その日の実行サマリー。強制ループが読む契約フィールドを含む |
| `<date>.log` | runner の詳細ログ |
| `launchd.out.log` / `launchd.err.log` | launchd が捕捉した標準出力 / エラー（PATH 問題の一次情報） |

## summary.md の契約フィールド（Phase 2 で本格使用）

ランチャ（runner.sh）が grep して完走判定するための機械可読フィールド:

```
**total_tasks_planned**: N   # 実行予定の job 総数
**total_tasks_started**:  M   # 確定状態に至った数
**iteration**: K              # 強制ループの周回数
**status**: completed_all | aborted_by_errors | aborted_by_safety
```

`_RUN COMPLETE_` センチネルが末尾にあれば、その run は最後まで到達している
（test-now はこれを完了検出に使う）。
