#!/usr/bin/env python3
# ============================================================================
# core/safety/guard.py — night-runner デフォルト安全境界（PreToolUse フック）
# ============================================================================
#
# claude の「外側」で危険操作を物理ブロックする層。
# `--dangerously-skip-permissions` で走っていても PreToolUse フックは発火し、
# permissionDecision:"deny" でツール実行を止められることを実機検証済み。
# → プロンプトインジェクションでプロンプトの指示が無視されても、この層は無効化されない。
#
# 止めるのは「誰の環境でも致命傷になる」4カテゴリ **だけ**（広げない＝完走性を殺さない）:
#   1. 破壊的削除（作業ディレクトリ外への rm -rf / dd / mkfs / diskutil 等）
#   2. 課金が発生する操作（クラウドのプロビジョニング/デプロイ）
#   3. 本番への push / deploy / 不可逆な外部送信
#   4. 認証情報・秘密情報の外部送信
# 上記以外は止めない。libe 固有（DB スキーマ等）は入れない。
#
# 契約: stdin に PreToolUse の JSON。deny する時は stdout に
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# を出して exit 0。許可は「何も出さず exit 0」。
# ============================================================================

import sys, os, json, re

SENDERS = r'\b(curl|wget|nc|ncat|netcat|scp|sftp|rsync|ftp|telnet|sendmail|mail)\b'
SECRETS = (r'(\.env\b|\.ssh/|id_rsa|id_ed25519|id_ecdsa|\.pem\b|\.p12\b|\.netrc'
           r'|credentials\b|secret|token|password|passwd|api[_-]?key|access[_-]?key'
           r'|private[_-]?key|AWS_SECRET|AWS_ACCESS_KEY|keychain)')

CATASTROPHIC = [
    (r'\bmkfs(\.\w+)?\b', 'ファイルシステム作成(mkfs)'),
    (r'\bdd\b[^\n;|&]*\bof=/dev/', 'ディスクへの dd 書き込み'),
    (r'\bdiskutil\s+(erase|reformat|partitiondisk|zerodisk)', 'diskutil ディスク消去'),
    (r'>\s*/dev/(r?disk|sd)', 'デバイスへの直接書き込み'),
    (r'\bshred\b', 'shred によるファイル抹消'),
    (r':\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:', 'フォークボム'),
]

PUSH_DEPLOY = [
    (r'\bgit\s+push\b.*(--force\b|--force-with-lease\b|\s-f\b)', 'git 強制 push'),
    (r'\bgit\s+push\b', 'git push（外部・不可逆）'),
    (r'\bgh\s+pr\s+merge\b', 'PR マージ'),
    (r'\bgh\s+release\b', 'GitHub リリース'),
    (r'\b(npm|yarn|pnpm)\s+publish\b', 'パッケージ publish'),
    (r'\b(npm|yarn|pnpm)\s+run\s+deploy\b', 'run deploy'),
    (r'\bfirebase\s+deploy\b', 'firebase deploy'),
    (r'\bvercel\b.*(--prod\b|\bdeploy\b)', 'vercel deploy'),
    (r'\bnetlify\b.*\bdeploy\b', 'netlify deploy'),
    (r'\b(serverless|sls)\s+deploy\b', 'serverless deploy'),
    (r'\bfly(ctl)?\s+deploy\b', 'fly deploy'),
    (r'\beb\s+deploy\b', 'Elastic Beanstalk deploy'),
    (r'\bterraform\s+(apply|destroy)\b', 'terraform apply/destroy'),
    (r'\bkubectl\s+(apply|delete|replace|create|patch)\b', 'kubectl 変更操作'),
    (r'\bgcloud\b.*\b(deploy|create)\b', 'gcloud デプロイ/作成（課金）'),
    (r'\baws\b.*(\bdeploy\b|\bcreate-|\brun-instances\b|s3\s+sync)', 'aws デプロイ/作成（課金）'),
    (r'\baz\b.*\b(create|deploy)\b', 'az 作成/デプロイ（課金）'),
    (r'\bheroku\b.*\b(deploy|run)\b', 'heroku deploy'),
    (r'\bcap\b.*\bdeploy\b', 'capistrano deploy'),
    (r'\bdocker\s+push\b', 'docker push（レジストリ送信）'),
]

DANGER_MCP = [
    (r'merge_pull_request', 'PR マージ'),
    (r'push_files', 'リモートへの push'),
    (r'create_or_update_file', 'リモートリポジトリへの書き込み'),
    (r'create_release', 'リリース作成'),
    (r'deploy', 'デプロイ'),
]


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "[night-runner safety] " + reason}}))
    _log(reason)
    sys.exit(0)


def allow():
    sys.exit(0)  # 出力なし＝通常フロー（許可）


def _log(reason):
    runs = os.environ.get("NR_RUNS_DIR")
    if not runs:
        return
    try:
        import datetime
        with open(os.path.join(runs, "safety.log"), "a") as f:
            f.write("%s DENY %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), reason))
    except Exception:
        pass


def is_dangerous_target(t, root):
    t0 = t.strip().strip('"').strip("'")
    if t0 in ('/', '~', '~/', '*', '.', './', '..', '$HOME', '${HOME}'):
        return True
    if t0.startswith('~') or t0.startswith('$HOME') or t0.startswith('${HOME}'):
        return True
    if '..' in t0.split('/'):
        return True
    if t0.startswith('/'):
        rp = os.path.realpath(t0)
        return not (rp == root or rp.startswith(root + os.sep))
    rp = os.path.realpath(os.path.join(root, t0))
    if rp == root:          # 作業ディレクトリ自体を丸ごと削除
        return True
    return not rp.startswith(root + os.sep)


def check_rm(cmd, root):
    import shlex
    for seg in re.split(r'(?:&&|\|\||;|\n|\|)', cmd):
        try:
            argv = shlex.split(seg)
        except Exception:
            argv = seg.split()
        i = 0
        # 先頭の sudo / VAR=val を読み飛ばす
        while i < len(argv) and (argv[i] == 'sudo' or re.match(r'^[A-Za-z_]\w*=', argv[i])):
            i += 1
        if i >= len(argv) or os.path.basename(argv[i]) != 'rm':
            continue
        rest = argv[i + 1:]
        short = ''.join(a[1:] for a in rest if a.startswith('-') and not a.startswith('--'))
        longs = [a for a in rest if a.startswith('--')]
        recursive = ('r' in short) or ('R' in short) or ('--recursive' in longs)
        force = ('f' in short) or ('--force' in longs)
        if not (recursive and force):
            continue
        targets = [a for a in rest if not a.startswith('-')]
        if not targets:           # rm -rf （対象未指定でも危険寄り）
            continue
        for t in targets:
            if is_dangerous_target(t, root):
                deny("作業ディレクトリ外/危険な再帰削除: rm ... %s" % t)


def check_bash(cmd, root):
    for pat, label in CATASTROPHIC:
        if re.search(pat, cmd, re.I):
            deny("破壊的操作: " + label)
    check_rm(cmd, root)
    for pat, label in PUSH_DEPLOY:
        if re.search(pat, cmd, re.I):
            deny("本番/デプロイ/不可逆送信: " + label)
    if re.search(SENDERS, cmd, re.I) and re.search(SECRETS, cmd, re.I):
        deny("秘密情報の外部送信の疑い（ネットワーク送信＋秘密参照）")
    if re.search(r'\bsecurity\s+(find-generic-password|find-internet-password|dump-keychain)', cmd, re.I):
        deny("Keychain からの秘密取り出し")


def check_mcp(tool):
    for pat, label in DANGER_MCP:
        if re.search(pat, tool, re.I):
            deny("MCP 外部不可逆操作: %s（%s）" % (tool, label))


def check_webfetch(ti):
    blob = json.dumps(ti)
    if re.search(SECRETS, blob, re.I) and re.search(r'https?://', blob, re.I):
        deny("WebFetch リクエストに秘密情報が含まれる疑い")


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        # 入力が解釈できない＝判定不能 → fail-closed（安全側で拒否）
        deny("ツール入力を解釈できなかったため安全側で拒否")
        return
    tool = data.get("tool_name", "") or ""
    ti = data.get("tool_input", {}) or {}
    root = os.environ.get("NR_ROOT") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    root = os.path.realpath(root)

    if tool == "Bash":
        check_bash(ti.get("command", "") or "", root)
    elif tool.startswith("mcp__"):
        check_mcp(tool)
    elif tool == "WebFetch":
        check_webfetch(ti)
    allow()


if __name__ == "__main__":
    main()
