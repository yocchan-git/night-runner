#!/usr/bin/env bash
# ============================================================================
# core/runner.sh — launchd が叩く本体（コア / ユーザーは触らない）
# ============================================================================
#
# このスクリプトがやることは、最終的に3つだけ（資料 2-2）:
#   ① 環境準備（config 読み込み・PATH 確定・runs ディレクトリ作成）
#   ② Claude を非対話起動（claude -p）して登録 job を実行  … Phase 1 で実装
#   ③ 強制ループ（summary の started<planned を見て自分を exec 再起動） … Phase 2 で実装
#
# === Phase 0（現状）===
# まだ②③は無い。Phase 0 のゴールは「launchd 経由で即時に起動でき、
# その極小 PATH 環境でも claude / node が解決できることを確認する」こと（資料 2-1）。
# よってここでは「心拍（heartbeat）+ ツール解決チェック」だけを行い、
# 結果を runs/<date>-summary.md に書く。
#
# 即時テスト: Claude に「今すぐテストして」と頼む（test-now スキルが launchctl start を叩く）。
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

mkdir -p "$NR_RUNS_DIR"

{
  echo "==== runner start ${RUN_TS} (PID $$) ===="
  echo "PATH=${PATH}"
} >> "$LOG"

# --- ① 環境準備の検証：claude / node が PATH で解決できるか --------------------
# launchd の極小 PATH でここが落ちるのが最大のハマりどころ（資料 2-1）。
# config の NR_PATH が plist に正しく焼かれていれば解決できるはず。
CLAUDE_RESOLVED="$(nr_require_tool claude || true)"
NODE_RESOLVED="$(nr_require_tool node || true)"

TOOLS_OK="true"
[ -z "$CLAUDE_RESOLVED" ] && TOOLS_OK="false"
[ -z "$NODE_RESOLVED" ]   && TOOLS_OK="false"

# config に絶対パスが焼かれていれば fallback で拾う
if [ -z "$CLAUDE_RESOLVED" ] && [ -n "${NR_CLAUDE_BIN:-}" ] && [ -x "$NR_CLAUDE_BIN" ]; then
  CLAUDE_RESOLVED="$NR_CLAUDE_BIN (NR_CLAUDE_BIN fallback)"
fi

nr_log "runner Phase0 heartbeat — claude=[${CLAUDE_RESOLVED:-NOT FOUND}] node=[${NODE_RESOLVED:-NOT FOUND}]" "$LOG"

# --- summary 出力（強制ループ契約のフィールドを Phase 0 から用意）-------------
# Phase 2 でランチャがこの started/planned を grep して再起動判定する。
# Phase 0 では planned=0 / started=0（実行する job がまだ無い）。
{
  echo "# night-runner summary ${TODAY}"
  echo ""
  echo "**run_at**: ${RUN_TS}"
  echo "**phase**: 0 (heartbeat only)"
  echo "**total_tasks_planned**: 0"
  echo "**total_tasks_started**: 0"
  echo "**iteration**: ${NIGHT_RUNNER_ITERATION:-0}"
  echo "**status**: completed_all"
  echo ""
  echo "## 環境チェック"
  echo "- claude: ${CLAUDE_RESOLVED:-❌ NOT FOUND}"
  echo "- node:   ${NODE_RESOLVED:-❌ NOT FOUND}"
  echo "- PATH:   \`${PATH}\`"
  echo "- tools_ok: ${TOOLS_OK}"
  echo ""
  if [ "$TOOLS_OK" != "true" ]; then
    echo "> ⚠ launchd の PATH で claude/node が解決できていません。"
    echo "> install スキルで PATH を焼き直してください（資料 2-1 のハマりどころ）。"
    echo ""
  fi
  echo "_RUN COMPLETE_"
} > "$SUMMARY"

echo "==== runner end ${RUN_TS} (tools_ok=${TOOLS_OK}) ====" >> "$LOG"

if [ "$TOOLS_OK" = "true" ]; then
  nr_log "Phase0 OK — summary: $SUMMARY" "$LOG"
  exit 0
else
  nr_log "Phase0 NG — claude/node 未解決。summary を確認: $SUMMARY" "$LOG"
  exit 0   # Phase0 はテスト目的。NG でも exit 0（summary に記録済み）
fi
