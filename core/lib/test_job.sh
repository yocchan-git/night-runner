#!/usr/bin/env bash
# ============================================================================
# core/lib/test_job.sh — 1つの job だけを launchd 経由で即テスト（setup-job 用）
# ============================================================================
#
# 使い方: test_job.sh <job名> [timeout秒]
#
# Phase 0 の即テスト（test_now.sh = launchctl start）を、指定 1 job に絞って走らせる。
# runs/.only-job に名前を置く → runner が one-shot で enabled 無視でその job だけ実行。
# enabled フラグに関係なくテストできるので、夜間運用に載せる前に試せる。

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${LIB_DIR}/common.sh"
nr_load_config || exit 1

NAME="${1:-}"
TIMEOUT="${2:-300}"
if [ -z "$NAME" ]; then echo "使い方: test_job.sh <job名> [timeout秒]"; exit 2; fi
if [ ! -f "${NR_ROOT}/jobs/${NAME}/job.md" ]; then
  echo "❌ job が見つかりません: jobs/${NAME}/job.md"; exit 1
fi

mkdir -p "$NR_RUNS_DIR"
# only-job 指定
echo "$NAME" > "${NR_RUNS_DIR}/.only-job"
# 今日のこの job のマーカーを消して、確実に再実行させる
rm -f "${NR_RUNS_DIR}/state/$(date +%Y-%m-%d)/${NAME}.done"

echo "▶ '${NAME}' だけを即テストします（他の夜間 job は走りません）"
exec bash "${LIB_DIR}/test_now.sh" "$TIMEOUT"
