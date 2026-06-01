#!/usr/bin/env bash
# core/lib/common.sh — 全スクリプト共通の土台。
#   - リポジトリ root の解決
#   - config/config.sh の読み込み
#   - ログ / ツール存在チェックのヘルパ
#
# 各スクリプトの冒頭で source して使う:
#   source "$(dirname "$0")/lib/common.sh"   等

# このファイルは core/lib/ にあるので ../.. が repo root。
NR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NR_ROOT_DEFAULT="$(cd "${NR_LIB_DIR}/../.." && pwd)"

NR_CONFIG_FILE="${NR_CONFIG_FILE:-${NR_ROOT_DEFAULT}/config/config.sh}"

nr_load_config() {
  if [ ! -f "$NR_CONFIG_FILE" ]; then
    echo "night-runner: config が未生成です ($NR_CONFIG_FILE)." >&2
    echo "  Claude に「night-runner をインストールして」と頼んでください（install スキルが生成します）。" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "$NR_CONFIG_FILE"
  # config が NR_ROOT を持っていなければ既定値で補完。
  : "${NR_ROOT:=$NR_ROOT_DEFAULT}"
  : "${NR_RUNS_DIR:=$NR_ROOT/runs}"
}

# 時刻つきログ。第2引数にファイルが渡れば tee する。
nr_log() {
  local msg="$1"
  local file="${2:-}"
  local line
  line="[$(date +'%H:%M:%S')] $msg"
  if [ -n "$file" ]; then
    echo "$line" | tee -a "$file"
  else
    echo "$line"
  fi
}

# 必須ツールが PATH 上にあるか検査。無ければ which 解決を試み、見つからなければ 1。
# launchd 環境（PATH 極小）で claude/node が通っているかを早期に検出するための核心（資料 2-1）。
nr_require_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return 0
  fi
  return 1
}
