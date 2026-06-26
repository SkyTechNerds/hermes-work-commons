#!/bin/bash
# hermes-work — ai-reply.sh <owner/repo> <pr> <reply_comment_id>
# Beantwortet einen Reply auf ein EIGENES Inline-Finding via LLM (claude -p) und
# postet die Antwort im selben Thread — als App-Bot (Installation-Token via GH_TOKEN).
# Nur wenn der Parent-Kommentar vom Bot stammt; sonst no-op.
set -uo pipefail
[ "$#" -lt 3 ] && { echo "usage: ai-reply.sh <repo> <pr> <reply_comment_id>" >&2; exit 2; }
REPO="$1"; PR="$2"; CID="$3"

# Vorgegebenes Env-Token (App-Installation) hat Vorrang; sonst PAT laden.
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  case "$REPO" in
    *JUMO*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
    *)      TOKFILE=/etc/hermes-discord-listener/hank.token ;;
  esac
  export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
elif [ -z "${GH_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

REPLY_JSON="$(gh api "repos/$REPO/pulls/comments/$CID" 2>/dev/null)" || { echo "ai-reply: reply $CID nicht abrufbar"; exit 0; }
PARENT_ID="$(printf '%s' "$REPLY_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("in_reply_to_id") or "")')"
[ -z "$PARENT_ID" ] && { echo "ai-reply: kein in_reply_to (kein Reply)"; exit 0; }
PARENT_JSON="$(gh api "repos/$REPO/pulls/comments/$PARENT_ID" 2>/dev/null)" || { echo "ai-reply: parent $PARENT_ID nicht abrufbar"; exit 0; }
PTYPE="$(printf '%s' "$PARENT_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user",{}).get("type",""))')"
[ "$PTYPE" != "Bot" ] && { echo "ai-reply: Parent nicht vom Bot ($PTYPE) — ignoriert"; exit 0; }

RESP="$(REPLY_JSON="$REPLY_JSON" PARENT_JSON="$PARENT_JSON" python3 <<'PY' | claude -p 2>/dev/null
import os, json
r = json.loads(os.environ["REPLY_JSON"]); p = json.loads(os.environ["PARENT_JSON"])
print(f'''Du bist the-codemole[bot], ein freundlicher, präziser Code-Review-Bot. Du hast ein Inline-Finding zu einem Pull Request gepostet; der Entwickler hat darauf geantwortet. Antworte kurz und sachlich IM SELBEN THREAD.

Regeln:
- Korrektes Deutsch mit ECHTEN Umlauten (ä, ö, ü, ß), niemals ae/oe/ue/ss.
- Maximal 2-3 Sätze, kein Markdown-Geraffel, keine Begrüßungs-Floskeln.
- Wenn der Einwand berechtigt ist: räum es ein und zieh den Hinweis zurück (z. B. „Stimmt, dann passt es so.").
- Wenn dein Hinweis trotzdem gilt: erklär knapp und konkret warum.
- Bewerte nur diesen einen Punkt, starte kein neues Review.

DATEI: {r.get("path")} Zeile {r.get("line")}

DIFF-HUNK:
{(r.get("diff_hunk") or "")[-1200:]}

DEIN URSPRÜNGLICHES FINDING:
{p.get("body") or ""}

ANTWORT DES ENTWICKLERS:
{r.get("body") or ""}''')
PY
)"
[ -z "$RESP" ] && { echo "ai-reply: keine LLM-Antwort"; exit 0; }

if gh api -X POST "repos/$REPO/pulls/$PR/comments/$PARENT_ID/replies" -f body="$RESP" >/dev/null 2>&1; then
  echo "ai-reply: geantwortet auf #$PR (thread $PARENT_ID)"
else
  echo "ai-reply: posten fehlgeschlagen"
fi
