#!/bin/bash
# hermes-work — Claude-Logik-Review (ALLE Repos), $0 ueber `claude -p` (Max-Abo).
# Holt den PR-Diff -> laesst Claude reviewen -> postet zeilengenaue Inline-Kommentare.
# Laeuft separat vom Hermes-Agenten (MiniMax) -> zuverlaessig + CodeRabbit-Niveau.
# Usage: ai-review.sh <owner/repo> <pr>
set -uo pipefail
[ "$#" -lt 2 ] && { echo "usage: ai-review.sh <owner/repo> <pr>" >&2; exit 2; }
export REPO="$1" PR="$2"
export DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIFF="$("$DIR/pr-diff.sh" "$REPO" "$PR" 2>/dev/null | head -c 14000)"
[ -z "$DIFF" ] && { echo "ai-review: kein Diff"; exit 0; }

case "$REPO" in
  *JUMO*) CRIT="AEM EDS: fehlendes moveInstrumentation; Framework-Imports (React/Vue/jQuery); Imports ohne .js-Endung; img.src statt responsive Images; outline:none; hardcodierte Farben statt var(--); CSS-Nesting>3; Animationen auf Layout-Properties statt transform/opacity; Touch-Targets<44px." ;;
  *homeassistant-config*) CRIT="Home-Assistant-YAML/Automationen: Logik-Bugs (z.B. repeat-Loop mit fixem delay reagiert nicht sofort auf Zustandswechsel; Race-Conditions; fehlende stop/Bedingungen; falscher Modus single/restart/queued); native Trigger/Conditions statt Jinja; entity_id statt device_id; Helfer statt Template-Sensoren; Klartext-Secrets." ;;
  *ha-soft-presence*) CRIT="HA-Python-Integration: Blocking-Calls im async-Event-Loop; fehlendes async/await; config_flow-Konventionen; manifest.json-Pflichtfelder; Typing; Exception-Handling; Entity-Konventionen (unique_id, device_info)." ;;
  *) CRIT="Allgemeine Korrektheit, Bugs, Sicherheit." ;;
esac

PROMPT="Du bist ein praeziser, knapper Code-Reviewer. Pruefe NUR den folgenden PR-Diff auf konkrete Probleme nach diesen Kriterien:
$CRIT

Antworte AUSSCHLIESSLICH mit einem JSON-Array (keine Erklaerung, kein Markdown, keine Code-Fences). Format:
[{\"file\":\"<pfad>\",\"line\":<zeilennummer im NEUEN Code>,\"severity\":\"major|minor\",\"message\":\"<konkrete Begruendung + kurzer Fix, professionell, deutsch>\"}]
Zeilennummern aus den @@ -a,b +c,d @@-Hunks (rechte/neue Seite). Nur echte Findings, die WIRKLICH im Diff stehen. Wenn nichts Konkretes: []

DIFF:
$DIFF"

RESP="$(printf '%s' "$PROMPT" | claude -p 2>/dev/null)"
export RESP
python3 <<'PY'
import json, os, re, subprocess
resp = os.environ.get("RESP", "")
m = re.search(r'\[.*\]', resp, re.S)
items = []
if m:
    try: items = json.loads(m.group(0))
    except Exception: items = []
repo, pr, d = os.environ["REPO"], os.environ["PR"], os.environ["DIR"]
n = 0
for it in items:
    if not isinstance(it, dict): continue
    f, l, msg = it.get("file"), it.get("line"), it.get("message")
    if not (f and l and msg): continue
    sev = it.get("severity", "minor")
    body = ("⚠️ " if sev == "major" else "") + str(msg)
    try:
        subprocess.run([f"{d}/review-comment.sh", repo, pr, str(f), str(int(l)), body],
                       timeout=30, check=False)
        n += 1
    except Exception as e:
        print("post-fail:", e)
print(f"AI-REVIEW: {n} Finding(s) gepostet")
PY
