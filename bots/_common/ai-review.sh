#!/bin/bash
# hermes-work — Claude-Logik-Review (ALLE Repos), $0 über `claude -p` (Max-Abo).
# Holt den PR-Diff -> lässt Claude reviewen -> postet zeilengenaue Inline-Kommentare.
# Läuft separat vom Hermes-Agenten (MiniMax) -> zuverlässig + CodeRabbit-Niveau.
# Usage: ai-review.sh <owner/repo> <pr>
set -uo pipefail
[ "$#" -lt 2 ] && { echo "usage: ai-review.sh <owner/repo> <pr>" >&2; exit 2; }
export REPO="$1" PR="$2"
export DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Profil-Optionen aus .codemole.yml (ignore-Globs / ai-review.focus / ai-review.severity)
CM_IGNORE=""; CM_FOCUS=""; CM_SEVERITY=""
eval "$(python3 "$DIR/resolve-profile.py" "${REPO_DIR:-.}" "$REPO" 2>/dev/null | python3 -c '
import sys, json, shlex
try: r = json.load(sys.stdin)
except Exception: r = {}
opt = (r.get("options") or {}).get("ai-review") or {}
print("CM_IGNORE=" + shlex.quote("\n".join(r.get("ignore") or [])))
print("CM_FOCUS=" + shlex.quote(str(opt.get("focus") or "")))
print("CM_SEVERITY=" + shlex.quote(str(opt.get("severity") or "")))
' 2>/dev/null)"

DIFF="$("$DIR/pr-diff.sh" "$REPO" "$PR" 2>/dev/null | head -c 14000)"
[ -z "$DIFF" ] && { echo "ai-review: kein Diff"; exit 0; }

# ignore-Globs: ganze Datei-Blöcke aus dem Diff werfen (kein Review auf generierten/Vendor-Pfaden)
if [ -n "$CM_IGNORE" ]; then
  DIFF="$(CM_IGNORE="$CM_IGNORE" DIFF_IN="$DIFF" python3 -c '
import os, re, fnmatch
globs = [g for g in os.environ["CM_IGNORE"].split("\n") if g]
def ig(p):
    for g in globs:
        g2 = g.replace("**/", "").replace("**", "*")
        if fnmatch.fnmatch(p, g) or fnmatch.fnmatch(p, g2) or fnmatch.fnmatch(p, "*/" + g2):
            return True
    return False
txt = os.environ["DIFF_IN"]
keep = []
for b in re.split(r"(?m)(?=^=== FILE: )", txt):
    m = re.match(r"=== FILE: (.+?) \(", b)
    if m and ig(m.group(1)):
        continue
    keep.append(b)
print("".join(keep), end="")
')"
  [ -z "$DIFF" ] && { echo "ai-review: alle geänderten Dateien per ignore ausgenommen"; exit 0; }
fi

case "$REPO" in
  *JUMO*)
    # AEM-Regelwerk live aus dem Team-Wiki (Axiom-SMB) holen — Claude reviewt gegen die echten Projekt-Standards.
    AEM_RULES="$("$DIR/wiki-get.sh" concepts/role-aem-frontend.md; printf '\n\n'; "$DIR/wiki-get.sh" concepts/aem-blocks.md; printf '\n\n'; "$DIR/wiki-get.sh" concepts/aem-block-validator.md)"
    if [ "${#AEM_RULES}" -gt 500 ]; then
      CRIT="AEM Edge Delivery Services. Prüfe den Diff gegen DIESES Projekt-Regelwerk aus dem Team-Wiki (alle als PFLICHT markierten Regeln gelten):

$AEM_RULES"
    else
      # Fallback wenn Wiki nicht erreichbar
      CRIT="AEM EDS: fehlendes moveInstrumentation; Framework-Imports (React/Vue/jQuery); Imports ohne .js-Endung; img.src statt responsive Images; outline:none; hardcodierte Farben statt var(--); CSS-Nesting>3; Animationen auf Layout-Properties statt transform/opacity; Touch-Targets<44px."
    fi
    ;;
  *homeassistant-config*) CRIT="Home-Assistant-YAML/Automationen: Logik-Bugs (z.B. repeat-Loop mit fixem delay reagiert nicht sofort auf Zustandswechsel; Race-Conditions; fehlende stop/Bedingungen; falscher Modus single/restart/queued); native Trigger/Conditions statt Jinja; entity_id statt device_id; Helfer statt Template-Sensoren; Klartext-Secrets." ;;
  *ha-soft-presence*) CRIT="HA-Python-Integration: Blocking-Calls im async-Event-Loop; fehlendes async/await; config_flow-Konventionen; manifest.json-Pflichtfelder; Typing; Exception-Handling; Entity-Konventionen (unique_id, device_info)." ;;
  *) CRIT="Allgemeine Korrektheit, Bugs, Sicherheit." ;;
esac

# Zusätzlicher Review-Fokus aus .codemole.yml (ai-review.focus)
[ -n "$CM_FOCUS" ] && CRIT="$CRIT

Zusätzlicher Fokus (vom Repo via .codemole.yml): $CM_FOCUS"

PROMPT="Du bist ein präziser, knapper Code-Reviewer. Prüfe NUR den folgenden PR-Diff auf konkrete Probleme nach diesen Kriterien:
$CRIT

WICHTIG zur Sprache: Schreibe das message-Feld in korrektem Deutsch mit ECHTEN Umlauten (ä, ö, ü, ß). NIEMALS ASCII-Ersatz wie ae/oe/ue/ss verwenden — also 'fehleranfällig', nicht 'fehleranfaellig'.

Antworte AUSSCHLIESSLICH mit einem JSON-Array (keine Erklärung, kein Markdown, keine Code-Fences). Format:
[{\"file\":\"<pfad>\",\"line\":<zeilennummer im NEUEN Code>,\"severity\":\"major|minor\",\"message\":\"<konkrete Begründung + kurzer Fix, professionell, deutsch mit Umlauten>\"}]
Zeilennummern aus den @@ -a,b +c,d @@-Hunks (rechte/neue Seite). Nur echte Findings, die WIRKLICH im Diff stehen. Wenn nichts Konkretes: []

DIFF:
$DIFF"

RESP="$(printf '%s' "$PROMPT" | claude -p 2>/dev/null)"
export RESP CM_SEVERITY
python3 <<'PY'
import json, os, re, subprocess
resp = os.environ.get("RESP", "")
sevcfg = os.environ.get("CM_SEVERITY", "").strip().lower()
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
    if sevcfg == "major" and sev != "major":
        continue  # .codemole.yml: nur major-Findings posten
    body = ("⚠️ " if sev == "major" else "") + str(msg)
    try:
        subprocess.run([f"{d}/review-comment.sh", repo, pr, str(f), str(int(l)), body],
                       timeout=30, check=False)
        n += 1
    except Exception as e:
        print("post-fail:", e)
print(f"AI-REVIEW: {n} Finding(s) gepostet")
PY
