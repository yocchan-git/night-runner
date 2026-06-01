# night-runner

**あなたの定型作業を、夜のあいだに AI が無人で実行するプラットフォーム（macOS）。**

寝ているあいだに Claude Code が登録済みの作業を上から片付け、朝には結果がファイルに残っている。
あなたが触るのは**対話だけ**。ファイル・ターミナル・launchd の設定は AI がすべて裏で代行する。

> Naval "Inspiration is perishable" と Taleb のバーベル戦略の実装 ——
> 「触らない自由」を確保しつつ、夜の固定枠で複利を回す装置。

---

## 設計思想（4つの看板）

1. **止まらない**: 夜に走らせたら原則完走させ切る。LLM の「区切りが良い」式の早期停止を、
   プロンプトでなく**構造**（強制ループ）で殺す。
2. **でも致命傷だけは防ぐ**: 破壊的変更・課金・本番への不可逆操作だけは止める。
   ユーザー設定ゼロでもコアがデフォルトで守る。"何で止まり何で止まらないか" の非対称設計。
3. **ユーザーはファイル・ターミナル・plist を触らない**: 設定・登録・テスト・配備は全部 AI が代行。
4. **8割で動かして改善する**: 完璧を最初に目指さない。昼に即時テストで回して現実のズレを直す。

---

## 動く仕組み（一言）

```
launchd（毎晩）→ core/runner.sh → claude -p で登録 job を上から実行
   → runs/<date>-summary.md に進捗を書く
   → runner.sh が started<planned を見て、未完なら自分を再起動（上限 N）
```

---

## 使い方（すべて対話で）

night-runner ディレクトリで Claude Code を開き、話しかけるだけ:

- 「インストールして」 → `install` スキルが launchd 登録（PATH 検出・plist 配備まで自動）
- 「今すぐテストして」 → `test-now` スキルが本番と同じ環境で1回即時実行して結果を見せる
- （Phase 4 以降）「この作業を夜間に任せたい」 → `setup-job` スキルが対話で job 化・登録

---

## 構成

| 場所 | 役割 |
|---|---|
| `core/` | 再利用コア（ユーザーは触らない）。runner / plist テンプレ / プロンプト / 安全境界 |
| `config/config.sh` | マシン固有設定（install が生成・`.gitignore` 済み） |
| `jobs/` | あなたの定型作業（self-contained な job 定義。スキルが生成） |
| `.claude/skills/` | 対話の入口（install / test-now / setup-job …） |
| `runs/` | 実行結果（summary + log）。`.gitignore` 済み |
| `docs/` | アーキテクチャと安全設計の正本 |

---

## 実装状況

- [x] **Phase 0** — 即時テストの口（install / test-now / plist テンプレ / PATH 検出 / heartbeat runner）
- [x] **Phase 1** — 動く骨格（claude -p で enabled job を実行 → summary に契約フィールドを記録）
- [x] **Phase 2** — 止まらない制御（完了マーカーで進捗判定 → started<planned で exec 再起動・上限 N で明示 abort・再着手防止）
- [x] **Phase 3** — 致命傷を防ぐ（PreToolUse フックで claude の外側から危険操作を物理ブロック・該当 job だけ safety_blocked）
- [ ] Phase 4 — 入口（定型作業をスキル化するスキル）

> macOS 専用。Claude Code CLI（`claude`）が必要。
