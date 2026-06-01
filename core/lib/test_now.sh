#!/usr/bin/env bash
# ============================================================================
# core/lib/test_now.sh — 即時テスト実行（test-now スキルが叩く / Phase 0 の口）
# ============================================================================
#
# 夜を待たず、昼に launchd 経由で「今すぐ」runner を1回走らせて結果を見る。
#
# 設計判断: 資料では「plist の時刻を今に書換→reload→実行→戻す」とあったが、
# launchd には on-demand 起動の標準コマンド `launchctl start <label>` があり、
# これは StartCalendarInterval を一切いじらずに、本番と同一の launchd 環境
# （EnvironmentVariables の PATH 等）でジョブを発火できる。時刻書換は不要かつ
# タイミングが脆いので、本実装は launchctl start を使う。
# （時刻を一切汚さないので「終わったら元に戻す」工程自体が消える＝より安全）
#
# 使い方: test_now.sh [timeout_seconds]
#   Phase 0 の runner は心拍だけなので数秒で完了する。

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${LIB_DIR}/common.sh"
nr_load_config || exit 1

TIMEOUT="${1:-120}"
TODAY="$(date +%Y-%m-%d)"
SUMMARY="${NR_RUNS_DIR}/${TODAY}-summary.md"
START_EPOCH="$(date +%s)"

if [ -z "${NR_LABEL:-}" ]; then
  echo "❌ config に NR_LABEL がありません。先に install してください。"
  exit 1
fi

if ! launchctl list 2>/dev/null | grep -q "$NR_LABEL"; then
  echo "❌ $NR_LABEL が launchctl にロードされていません。先に install してください。"
  exit 1
fi

echo "▶ launchctl start $NR_LABEL （本番と同じ launchd 環境で即時実行）"
launchctl start "$NR_LABEL"

# summary が START 以降に更新され、完了センチネルを含むまで待つ
echo "  完了待ち（最大 ${TIMEOUT}s）..."
DONE="false"
for _ in $(seq 1 "$TIMEOUT"); do
  if [ -f "$SUMMARY" ]; then
    MTIME="$(stat -f %m "$SUMMARY" 2>/dev/null || echo 0)"
    if [ "$MTIME" -ge "$START_EPOCH" ] && grep -q "_RUN COMPLETE_" "$SUMMARY" 2>/dev/null; then
      DONE="true"
      break
    fi
  fi
  sleep 1
done

echo ""
echo "================= summary ================="
if [ -f "$SUMMARY" ]; then
  cat "$SUMMARY"
else
  echo "(summary がまだ生成されていません)"
fi
echo "==========================================="
echo ""

LOG="${NR_RUNS_DIR}/${TODAY}.log"
if [ -f "$LOG" ]; then
  echo "----- log (tail) -----"
  tail -20 "$LOG"
  echo "----------------------"
fi

if [ "$DONE" = "true" ]; then
  echo "✅ 即時テスト完了。"
  exit 0
else
  echo "⚠ ${TIMEOUT}s 以内に完了センチネルを確認できませんでした。"
  echo "  launchd ログ: ${NR_RUNS_DIR}/launchd.err.log を確認してください。"
  exit 1
fi
