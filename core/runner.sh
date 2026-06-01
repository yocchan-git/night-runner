#!/usr/bin/env bash
# ============================================================================
# core/runner.sh — launchd が叩く本体（コア / ユーザーは触らない）
# ============================================================================
#
# このスクリプトがやることは3つだけ（資料 2-2）:
#   ① 環境準備（config 読み込み・PATH 確定・runs 作成・claude 解決確認）
#   ② Claude を非対話起動（claude -p）して登録 job を上から実行  ← Phase 1（本実装）
#   ③ 強制ループ（summary の started<planned を見て自分を exec 再起動） … Phase 2 で追加
#
# 即時テスト: Claude に「今すぐテストして」（test-now スキルが launchctl start を叩く）。
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
JOBS_DIR="${NR_ROOT}/jobs"
ORCHESTRATOR="${NR_ROOT}/core/prompts/orchestrator.md"
ITERATION="${NIGHT_RUNNER_ITERATION:-0}"
MAX_TURNS="${NR_MAX_TURNS:-60}"

mkdir -p "$NR_RUNS_DIR"

{
  echo "==== runner start ${RUN_TS} (PID $$, iteration ${ITERATION}) ===="
  echo "PATH=${PATH}"
} >> "$LOG"

# fallback summary を書くヘルパ（claude が summary を残せなかった時用）
write_fallback_summary() {
  local status="$1" planned="$2" started="$3" note="$4"
  {
    echo "# night-runner summary ${TODAY}"
    echo ""
    echo "**run_at**: ${RUN_TS}"
    echo "**phase**: 1"
    echo "**total_tasks_planned**: ${planned}"
    echo "**total_tasks_started**: ${started}"
    echo "**iteration**: ${ITERATION}"
    echo "**status**: ${status}"
    echo ""
    echo "## 失敗 (failed)"
    echo "- ${note}"
    echo ""
    echo "_RUN COMPLETE_"
  } > "$SUMMARY"
}

# --- ① 環境準備：claude 解決確認（launchd の極小 PATH 対策 / 資料 2-1）-------
CLAUDE_RESOLVED="$(nr_require_tool claude || true)"
if [ -z "$CLAUDE_RESOLVED" ] && [ -n "${NR_CLAUDE_BIN:-}" ] && [ -x "$NR_CLAUDE_BIN" ]; then
  CLAUDE_RESOLVED="$NR_CLAUDE_BIN"
fi
if [ -z "$CLAUDE_RESOLVED" ]; then
  nr_log "❌ claude が解決できない。PATH を確認（install をやり直す）。" "$LOG"
  write_fallback_summary "aborted_by_errors" 0 0 "claude CLI が PATH で解決できなかった（資料 2-1 の PATH 問題）"
  exit 0
fi
nr_log "claude=${CLAUDE_RESOLVED}" "$LOG"

# --- 登録 job の発見（enabled: true のものだけ）------------------------------
declare -a ENABLED_JOBS=()
if [ -d "$JOBS_DIR" ]; then
  while IFS= read -r jobfile; do
    [ -f "$jobfile" ] || continue
    # frontmatter の enabled: true を拾う
    if grep -qiE '^enabled:[[:space:]]*true' "$jobfile"; then
      ENABLED_JOBS+=("$jobfile")
    fi
  done < <(find "$JOBS_DIR" -mindepth 2 -maxdepth 2 -name 'job.md' | sort)
fi

PLANNED="${#ENABLED_JOBS[@]}"
nr_log "enabled jobs: ${PLANNED}" "$LOG"

if [ "$PLANNED" -eq 0 ]; then
  nr_log "実行対象なし。summary を書いて終了。" "$LOG"
  {
    echo "# night-runner summary ${TODAY}"
    echo ""
    echo "**run_at**: ${RUN_TS}"
    echo "**phase**: 1"
    echo "**total_tasks_planned**: 0"
    echo "**total_tasks_started**: 0"
    echo "**iteration**: ${ITERATION}"
    echo "**status**: completed_all"
    echo ""
    echo "## 完了タスク"
    echo "- (enabled な job がありません)"
    echo ""
    echo "_RUN COMPLETE_"
  } > "$SUMMARY"
  exit 0
fi

# --- ② プロンプト組み立て（orchestrator 本体 + 動的な実行コンテキスト）-------
PROMPT="$(cat "$ORCHESTRATOR")

---

## 実行コンテキスト（このセッション固有）

- date: ${TODAY}
- iteration: ${ITERATION}
- summary を書くパス（絶対パス）: ${SUMMARY}
- total_tasks_planned: ${PLANNED}
- 作業の足場ディレクトリ: ${NR_RUNS_DIR}

## 実行する job（上から順に / 全 ${PLANNED} 件）
"

JOB_INDEX=0
for jobfile in "${ENABLED_JOBS[@]}"; do
  JOB_INDEX=$((JOB_INDEX + 1))
  jobdir="$(dirname "$jobfile")"
  PROMPT="${PROMPT}
### job ${JOB_INDEX}: $(basename "$jobdir")
（job ファイル: ${jobfile}）

$(cat "$jobfile")
"
done

# --- ③ Claude 非対話起動 ----------------------------------------------------
nr_log "claude -p 起動（max-turns ${MAX_TURNS}）..." "$LOG"
{
  echo "---- CLAUDE OUTPUT (iteration ${ITERATION}) ----"
} >> "$LOG"

set +e
"$CLAUDE_RESOLVED" --print "$PROMPT" \
  --dangerously-skip-permissions \
  --max-turns "$MAX_TURNS" >> "$LOG" 2>&1
CLAUDE_EXIT=$?
set -e 2>/dev/null || true

{
  echo "---- END CLAUDE OUTPUT (exit ${CLAUDE_EXIT}) ----"
} >> "$LOG"
nr_log "claude 終了 (exit ${CLAUDE_EXIT})" "$LOG"

# --- post-check: summary が契約通り書かれたか --------------------------------
if [ -f "$SUMMARY" ] && grep -q "_RUN COMPLETE_" "$SUMMARY"; then
  STARTED="$(grep -oE 'total_tasks_started\*\*:[[:space:]]*[0-9]+' "$SUMMARY" | grep -oE '[0-9]+' | head -1 || echo 0)"
  nr_log "✅ summary OK — started=${STARTED}/${PLANNED}" "$LOG"
  exit 0
else
  nr_log "❌ claude が契約通りの summary を残さなかった。fallback を書く。" "$LOG"
  write_fallback_summary "aborted_by_errors" "$PLANNED" 0 "claude が summary（_RUN COMPLETE_ 付き）を生成しなかった。exit=${CLAUDE_EXIT}。詳細は ${LOG}"
  exit 0
fi
