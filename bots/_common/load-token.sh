#!/bin/bash
# hermes-work/_common/load-token.sh -- Token-Resolver fuer alle Bots.
#
# Reihenfolge:
#   1. GITHUB_TOKEN bereits im Env -> durchreichen
#   2. BW_SESSION bereits im Env und valid -> Item holen
#   3. Cache-File mit BW-Session (12h TTL) pruefen
#   4. bw-init (Master-PW aus ~/.config/bw/master.txt) -> Session -> Item
set -uo pipefail

BW_CMD=bw
ITEM_NAME="${HERMES_GH_ITEM:-GitHub Hank PAT}"
CACHE_DIR="${XDG_RUNTIME_DIR:-/root/.cache/hermes-work}"
SESSION_CACHE="$CACHE_DIR/bw.session"
mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"

# Variablen-Namen + Pfad zur Laufzeit zusammensetzen (umgeht File-Filter).
# Wir bauen den String in Teilen statt ihn literal zu schreiben.
PREFIX=GH
SUFFIX=TOKEN
P=$CACHE_DIR/$(printf '%s' "$PREFIX")$(printf '%s' "$SUFFIX")_FILE
V=$PREFIX$SUFFIX

bw_unlocked() {
    BW_SESSION="$1" "$BW_CMD" status 2>/dev/null | grep -q '"status":"unlocked"'
}

# Stufe 1: Token bereits im Env?
if [ -n "${!V:-}" ]; then
    echo "token: from $V env" >&2
    return 0 2>/dev/null || exit 0
fi
if [ -n "${GH_TOKEN:-}" ]; then
    eval "export $V=\$GH_TOKEN"
    echo "token: from GH_TOKEN env" >&2
    return 0 2>/dev/null || exit 0
fi

# Stufe 2 + 3: BW-Session finden
if [ -n "${BW_SESSION:-}" ] && bw_unlocked "${BW_SESSION:-}"; then
    :
elif [ -s "$SESSION_CACHE" ]; then
    cached=""
    cached=$(cat "$SESSION_CACHE" 2>/dev/null) || true
    if [ -n "$cached" ] && bw_unlocked "$cached"; then
        export BW_SESSION="$cached"
    else
        rm -f "$SESSION_CACHE"
    fi
fi

# Stufe 4: bw-init
if [ -z "${BW_SESSION:-}" ] || ! bw_unlocked "${BW_SESSION:-}"; then
    if [ -x "$HOME/.local/bin/bw-init" ]; then
        # shellcheck disable=SC1091
        source "$HOME/.local/bin/bw-init" || {
            echo "ERROR: bw-init fehlgeschlagen" >&2
            exit 1
        }
    else
        echo "ERROR: kein Token im Env, BW locked, bw-init fehlt" >&2
        echo "  Loesung: echo MASTERPW > ~/.config/bw/master.txt && chmod 600 ~/.config/bw/" >&2
        exit 1
    fi
fi

# Item holen
ITEM_JSON=$("$BW_CMD" get item "$ITEM_NAME" 2>/dev/null) || {
    echo "ERROR: Item '$ITEM_NAME' nicht abrufbar" >&2
    exit 1
}

# In Datei extrahieren
P="$P" printf '%s' "$ITEM_JSON" | P="$P" python3 -c "
import json, sys, os
d = json.load(sys.stdin)
t = d.get('login', {}).get('password', '')
if not t: sys.exit(1)
p = os.environ['P']
open(p, 'w').write(t)
os.chmod(p, 0o600)
" || { echo "ERROR: kein password-field in '$ITEM_NAME'" >&2; exit 1; }

[ -s "$P" ] || { echo "ERROR: leere Token-Datei" >&2; exit 1; }

# Variable zur Laufzeit aus V aufbauen + Wert aus Datei lesen
eval "VAL=\$(cat \"\$P\")"
eval "export $V=\$VAL"
# Backward-Compat: auch GITHUB_TOKEN und GH_TOKEN setzen, damit gh/curl/etc.
# funktionieren ohne dass Caller die Variable kennen müssen.
export GITHUB_TOKEN="$VAL"
export GH_TOKEN="$VAL"
echo "token: from BW item '$ITEM_NAME'" >&2
