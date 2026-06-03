# night-runner config — 環境ごとの設定（5-B の差し替えポイントを一箇所に隔離）
#
# このファイルは雛形。`install` スキルが which で各パスを検出して
#   config/config.sh
# を生成する。ユーザーは手で編集しなくてよい（触りたければ触れる、というだけ）。
#
# config.sh は .gitignore 済み（マシン固有・パス直書きを公開リポジトリに混ぜない）。

# ---- パス -------------------------------------------------------------------
# night-runner リポジトリの絶対パス。install スキルが現在地から自動で埋める。
NR_ROOT="__NR_ROOT__"

# 実行結果（summary / log）の出力先。
NR_RUNS_DIR="${NR_ROOT}/runs"

# ---- launchd ----------------------------------------------------------------
# LaunchAgent のラベル。`launchctl start <label>` で即時テストする時のキー。
NR_LABEL="__NR_LABEL__"

# 夜間に発火する時刻（24h）。
NR_SCHEDULE_HOUR="0"
NR_SCHEDULE_MINUTE="0"

# launchd セッションは PATH が極小（資料 2-1）。node/npx/claude が通るよう、
# install スキルが which で検出した実パスからこの PATH を組み立てて焼き込む。
NR_PATH="__NR_PATH__"

# claude CLI の絶対パス（PATH に依存せず確実に叩くため）。
NR_CLAUDE_BIN="__NR_CLAUDE_BIN__"

# HOME（launchd EnvironmentVariables に渡す）。
NR_HOME="__NR_HOME__"

# ---- 強制ループ（Phase 2 で使用）-------------------------------------------
# started < planned の時に自分自身を exec 再起動する上限回数。
NR_MAX_ITERATIONS="10"

# ---- 安全境界（Phase 3 で使用）---------------------------------------------
# コアの core/safety/default-deny.md は常に効く。ここにプロジェクト固有の
# 追加停止カテゴリを足せる（5-C-4）。Phase 3 で本実装。
NR_EXTRA_DENY_FILE=""

# 「意図した外部送信だけ通す」allowlist（guard.py が参照）は秘密と一緒に .env に置く。
# 例: NR_ALLOWED_SEND_URLS='^https://api\.example\.com/v1/notify$'
# 詳細は .env.example を参照（必ず単一引用符で囲む）。
