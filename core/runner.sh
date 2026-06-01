#!/usr/bin/env bash
# ============================================================================
# core/runner.sh — launchd が叩く本体（コア / ユーザーは触らない）
# ============================================================================
#
# やることは3つ（資料 2-2）:
#   ① 環境準備（config 読み込み・CWD/PATH 確定・claude 解決確認）
#   ② Claude を非対話起動（claude -p）して「未完 job」を上から実行
#   ③ 強制ループ：完了マーカー数 < planned かつ iteration < N なら exec で新規セッション再起動
#
# === 進捗のグラウンドトゥルース = per-job 完了マーカー ===
# 各 job は確定すると runs/state/<date>/<job>.done を書く（orchestrator の責務）。
# ランチャはこのマーカー数を started として数え、再起動を判断する。
# → claude の自己申告 summary に依存しない。「started=0 だが work 済み」を防ぐ。
# → 新規セッションはマーカーのある job をスキップ＝再着手しない（資料 3-2）。
#
# === 停止条件（無限ループ防止）===
#   - 全 job にマーカー（started==planned）→ status: completed_all で終了
#   - iteration が上限 N に達してなお未完 → status: aborted_max_iterations で終了
#   summary（契約フィールド + _RUN COMPLETE_）はこのランチャが終端で書く。
#
# 即時テスト: test-now スキル（launchctl start）。
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

nr_load_config || exit 1

TODAY="$(date +%Y-%m-%d)"
RUN_TS="$(date +'%Y-%m-%d %H:%M:%S')"
SUMMARY="${NR_RUNS_DIR}/${TODAY}-summary.md"
LOG="${NR_RUNS_DIR}/${TODAY}.log"
STATE_DIR="${NR_RUNS_DIR}/state/${TODAY}"
JOBS_DIR="${NR_ROOT}/jobs"
ORCHESTRATOR="${NR_ROOT}/core/prompts/orchestrator.md"
ITERATION="${NIGHT_RUNNER_ITERATION:-0}"
MAX_TURNS="${NR_MAX_TURNS:-60}"
MAX_ITER="${NR_MAX_ITERATIONS:-10}"

mkdir -p "$NR_RUNS_DIR" "$STATE_DIR"

# CWD を repo root に固定（launchd 起動だと CWD 不定で相対パス job が壊れる / 実測）
cd "$NR_ROOT" || { echo "cd $NR_ROOT 失敗" >> "$LOG"; exit 1; }

# 安全ガード（PreToolUse フック guard.py）が参照する env を export する。
export NR_ROOT NR_RUNS_DIR

{
  echo "==== runner start ${RUN_TS} (PID $$, iteration ${ITERATION}/${MAX_ITER}) ===="
  echo "CWD=$(pwd)"
} >> "$LOG"

# --- enabled job の発見 ------------------------------------------------------
declare -a JOB_NAMES=() JOB_FILES=()
if [ -d "$JOBS_DIR" ]; then
  while IFS= read -r jobfile; do
    [ -f "$jobfile" ] || continue
    grep -qiE '^enabled:[[:space:]]*true' "$jobfile" || continue
    JOB_NAMES+=("$(basename "$(dirname "$jobfile")")")
    JOB_FILES+=("$jobfile")
  done < <(find "$JOBS_DIR" -mindepth 2 -maxdepth 2 -name 'job.md' | sort)
fi
PLANNED="${#JOB_NAMES[@]}"

marker_path() { echo "${STATE_DIR}/$1.done"; }

# マーカーのある（確定済み）job 数を数える
count_done() {
  local n=0 i
  for ((i=0; i<PLANNED; i++)); do
    [ -f "$(marker_path "${JOB_NAMES[$i]}")" ] && n=$((n+1))
  done
  echo "$n"
}

# 終端 summary を書く（契約フィールド + 人間可読 + sentinel）。author = ランチャ。
write_summary() {
  local status="$1" started sb=0 i name m
  started="$(count_done)"
  for ((i=0; i<PLANNED; i++)); do
    m="$(marker_path "${JOB_NAMES[$i]}")"
    [ -f "$m" ] && head -1 "$m" | grep -qi '^safety_blocked' && sb=$((sb+1))
  done
  {
    echo "# night-runner summary ${TODAY}"
    echo ""
    echo "**run_at**: ${RUN_TS}"
    echo "**phase**: 3"
    echo "**total_tasks_planned**: ${PLANNED}"
    echo "**total_tasks_started**: ${started}"
    echo "**safety_blocked**: ${sb}"
    echo "**iteration**: ${ITERATION}"
    echo "**status**: ${status}"
    echo ""
    echo "## タスク結果"
    if [ "$PLANNED" -eq 0 ]; then
      echo "- (enabled な job がありません)"
    else
      local i name m
      for ((i=0; i<PLANNED; i++)); do
        name="${JOB_NAMES[$i]}"
        m="$(marker_path "$name")"
        if [ -f "$m" ]; then
          echo "- ${name}: $(head -1 "$m")"
        else
          echo "- ${name}: ⏳ 未確定（マーカーなし）"
        fi
      done
    fi
    echo ""
    echo "_RUN COMPLETE_"
  } > "$SUMMARY"
}

# --- ① claude 解決確認（launchd 極小 PATH 対策 / 資料 2-1）-------------------
CLAUDE_RESOLVED="$(nr_require_tool claude || true)"
if [ -z "$CLAUDE_RESOLVED" ] && [ -n "${NR_CLAUDE_BIN:-}" ] && [ -x "$NR_CLAUDE_BIN" ]; then
  CLAUDE_RESOLVED="$NR_CLAUDE_BIN"
fi
if [ -z "$CLAUDE_RESOLVED" ]; then
  nr_log "❌ claude 未解決。PATH を確認（install やり直し）。" "$LOG"
  write_summary "aborted_by_errors"
  exit 0
fi

nr_log "claude=${CLAUDE_RESOLVED} / planned=${PLANNED} / done(before)=$(count_done)" "$LOG"

# job が無ければ即終了
if [ "$PLANNED" -eq 0 ]; then
  nr_log "実行対象なし。" "$LOG"
  write_summary "completed_all"
  exit 0
fi

# 全部確定済みなら（前周回で完了）summary だけ書いて終了
DONE_BEFORE="$(count_done)"
if [ "$DONE_BEFORE" -ge "$PLANNED" ]; then
  nr_log "全 job 確定済み（${DONE_BEFORE}/${PLANNED}）。完了で終了。" "$LOG"
  write_summary "completed_all"
  exit 0
fi

# --- 安全ガードの前提確認（fail-closed）------------------------------------
# guard.py（PreToolUse フック）は python3 で動く。python3 が無いとフック自体が
# 起動できず fail-open（危険操作が素通り）になる。それは致命的なので、その場合は
# claude を起動せずバッチを中止する（安全側に倒す）。
if ! nr_require_tool python3 >/dev/null 2>&1; then
  nr_log "❌ python3 未解決 → 安全ガードを動かせない。fail-closed でバッチ中止。" "$LOG"
  write_summary "aborted_by_errors"
  exit 0
fi

# --- ② プロンプト組み立て：未完 job だけを渡す ------------------------------
DONE_LIST="" PENDING_BLOCK="" PENDING_COUNT=0
for ((i=0; i<PLANNED; i++)); do
  name="${JOB_NAMES[$i]}"; jobfile="${JOB_FILES[$i]}"; m="$(marker_path "$name")"
  if [ -f "$m" ]; then
    DONE_LIST="${DONE_LIST} ${name}"
  else
    PENDING_COUNT=$((PENDING_COUNT+1))
    PENDING_BLOCK="${PENDING_BLOCK}
### 未完 job ${PENDING_COUNT}: ${name}
- 完了マーカーのパス（確定したらここに書く）: ${m}
- job ファイル: ${jobfile}

$(cat "$jobfile")
"
  fi
done

PROMPT="$(cat "$ORCHESTRATOR")

---

## 実行コンテキスト（このセッション固有）

- date: ${TODAY}
- iteration: ${ITERATION}
- 作業ディレクトリ（相対パス基準）: ${NR_ROOT}
- 完了マーカー置き場: ${STATE_DIR}/<job名>.done
- 既に確定済み（**スキップ対象・触るな**）:${DONE_LIST:- （なし）}

## 今回やる「未完 job」（上から順に / ${PENDING_COUNT} 件）
${PENDING_BLOCK}"

# --- claude 非対話起動 ------------------------------------------------------
nr_log "claude -p 起動（pending=${PENDING_COUNT}, max-turns ${MAX_TURNS}）..." "$LOG"
echo "---- CLAUDE OUTPUT (iteration ${ITERATION}) ----" >> "$LOG"
set +e
"$CLAUDE_RESOLVED" --print "$PROMPT" \
  --dangerously-skip-permissions \
  --max-turns "$MAX_TURNS" >> "$LOG" 2>&1
CLAUDE_EXIT=$?
set -e 2>/dev/null || true
echo "---- END CLAUDE OUTPUT (exit ${CLAUDE_EXIT}) ----" >> "$LOG"

DONE_AFTER="$(count_done)"
nr_log "claude 終了 (exit ${CLAUDE_EXIT}) / done=${DONE_AFTER}/${PLANNED}" "$LOG"

# --- ③ 強制ループ判定（マーカー数を started とする）--------------------------
if [ "$DONE_AFTER" -ge "$PLANNED" ]; then
  nr_log "✅ 完走（${DONE_AFTER}/${PLANNED}）。" "$LOG"
  write_summary "completed_all"
  exit 0
fi

if [ "$ITERATION" -lt "$MAX_ITER" ]; then
  nr_log "⟳ 未完（${DONE_AFTER}/${PLANNED}）かつ iteration ${ITERATION}<${MAX_ITER} → 新規セッション再起動" "$LOG"
  # 進捗ゼロのまま再起動し続けると上限まで空回りするだけなので、それも N で必ず止まる。
  NIGHT_RUNNER_ITERATION=$((ITERATION+1)) exec "$0" "$@"
fi

# 上限到達してなお未完 → 明示的に aborted を記録して終了（無限ループ防止）
nr_log "⛔ 上限 ${MAX_ITER} 到達でなお未完（${DONE_AFTER}/${PLANNED}）。aborted。" "$LOG"
write_summary "aborted_max_iterations"
exit 0
