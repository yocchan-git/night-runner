#!/usr/bin/env bash
# ============================================================================
# core/lib/install.sh — night-runner を launchd に登録する（install スキルが叩く）
# ============================================================================
#
# やること:
#   1. リポジトリ root / ユーザー / ラベルを決める
#   2. claude / node / npx の実パスを which で検出して launchd 用 PATH を組む（資料 2-1）
#   3. config/config.example.sh を元に config/config.sh を生成（パス直書きを隔離）
#   4. plist テンプレートを描画して ~/Library/LaunchAgents/ に配備
#   5. launchctl で（再）ロード
#
# ユーザーは一切ファイルを触らない。Claude が install スキル経由でこれを実行する。

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NR_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"

USER_NAME="$(id -un)"
NR_LABEL="com.${USER_NAME}.night-runner"
NR_HOME="$HOME"
RUNNER_PATH="${NR_ROOT}/core/runner.sh"
RUNS_DIR="${NR_ROOT}/runs"
PLIST_DEST="${HOME}/Library/LaunchAgents/${NR_LABEL}.plist"
CONFIG_DEST="${NR_ROOT}/config/config.sh"
CONFIG_EXAMPLE="${NR_ROOT}/config/config.example.sh"
PLIST_TEMPLATE="${NR_ROOT}/core/runner.plist.template"

# 既定の実行時刻（後で config を編集すれば変えられる）
SCHEDULE_HOUR="${NR_SCHEDULE_HOUR:-0}"
SCHEDULE_MINUTE="${NR_SCHEDULE_MINUTE:-0}"

echo "▼ night-runner install"
echo "  root:  $NR_ROOT"
echo "  label: $NR_LABEL"

# --- 2. PATH 検出 -----------------------------------------------------------
# which で各ツールのディレクトリを集め、標準ディレクトリと合わせて重複排除。
declare -a PATH_DIRS=()
nr_add_dir() {
  local d="$1"
  [ -z "$d" ] && return 0
  [ ! -d "$d" ] && return 0
  for existing in "${PATH_DIRS[@]:-}"; do
    [ "$existing" = "$d" ] && return 0
  done
  PATH_DIRS+=("$d")
}

CLAUDE_BIN="$(command -v claude || true)"
NODE_BIN="$(command -v node || true)"
NPX_BIN="$(command -v npx || true)"

[ -n "$CLAUDE_BIN" ] && nr_add_dir "$(dirname "$CLAUDE_BIN")"
[ -n "$NODE_BIN" ]   && nr_add_dir "$(dirname "$NODE_BIN")"
[ -n "$NPX_BIN" ]    && nr_add_dir "$(dirname "$NPX_BIN")"

# よくある場所も保険で追加
nr_add_dir "${HOME}/.local/bin"
nr_add_dir "${HOME}/.nodenv/shims"
nr_add_dir "${HOME}/.pyenv/shims"
nr_add_dir "/opt/homebrew/bin"
nr_add_dir "/usr/local/bin"
nr_add_dir "/usr/bin"
nr_add_dir "/bin"
nr_add_dir "/usr/sbin"
nr_add_dir "/sbin"

NR_PATH="$(IFS=:; echo "${PATH_DIRS[*]}")"

echo "  claude: ${CLAUDE_BIN:-❌ NOT FOUND}"
echo "  node:   ${NODE_BIN:-❌ NOT FOUND}"
echo "  PATH:   $NR_PATH"

if [ -z "$CLAUDE_BIN" ]; then
  echo "  ⚠ claude が見つかりません。Claude Code CLI をインストールしてから再実行してください。"
fi

# --- 3. config.sh 生成 ------------------------------------------------------
# 既存 config.sh があれば上書き前に .bak を残す
if [ -f "$CONFIG_DEST" ]; then
  cp "$CONFIG_DEST" "${CONFIG_DEST}.bak"
  echo "  既存 config を ${CONFIG_DEST}.bak に退避"
fi

sed \
  -e "s|__NR_ROOT__|${NR_ROOT}|g" \
  -e "s|__NR_LABEL__|${NR_LABEL}|g" \
  -e "s|__NR_PATH__|${NR_PATH}|g" \
  -e "s|__NR_CLAUDE_BIN__|${CLAUDE_BIN}|g" \
  -e "s|__NR_HOME__|${NR_HOME}|g" \
  "$CONFIG_EXAMPLE" > "$CONFIG_DEST"
echo "  config 生成: $CONFIG_DEST"

# --- 4. plist 描画 + 配備 ---------------------------------------------------
mkdir -p "${HOME}/Library/LaunchAgents" "$RUNS_DIR"

sed \
  -e "s|__NR_LABEL__|${NR_LABEL}|g" \
  -e "s|__RUNNER_PATH__|${RUNNER_PATH}|g" \
  -e "s|__NR_PATH__|${NR_PATH}|g" \
  -e "s|__NR_HOME__|${NR_HOME}|g" \
  -e "s|__NR_SCHEDULE_HOUR__|${SCHEDULE_HOUR}|g" \
  -e "s|__NR_SCHEDULE_MINUTE__|${SCHEDULE_MINUTE}|g" \
  -e "s|__NR_RUNS_DIR__|${RUNS_DIR}|g" \
  "$PLIST_TEMPLATE" > "$PLIST_DEST"
echo "  plist 配備: $PLIST_DEST"

chmod +x "$RUNNER_PATH" 2>/dev/null || true

# --- 5. launchctl (再)ロード ------------------------------------------------
# pipefail + grep -q の SIGPIPE 偽陰性を避けるため変数経由で照合
LOADED="$(launchctl list 2>/dev/null || true)"
if grep -qF "$NR_LABEL" <<<"$LOADED"; then
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  echo "  既存ロードを unload"
fi
if launchctl load "$PLIST_DEST" 2>/dev/null; then
  echo "  ✅ launchctl load 完了"
else
  echo "  ❌ launchctl load 失敗"
  exit 1
fi

echo ""
echo "✅ install 完了。"
echo "   夜間実行: 毎日 ${SCHEDULE_HOUR}:$(printf '%02d' "$SCHEDULE_MINUTE")"
echo "   即時テスト: test-now スキル（launchctl start ${NR_LABEL}）"
