#!/bin/bash
# hermes-work — detect-lang.sh <owner/repo> <pr>
# Bestimmt die Ausgabesprache ("de" oder "en"):
#   1) expliziter Override in .codemole.yml (`lang: de|en`) — hat Vorrang
#   2) sonst Heuristik über PR-Titel + Beschreibung (Umlaute stark, Stopwort-Mehrheit)
# Env: REPO_DIR (für den .codemole.yml-Override), GH_TOKEN/GITHUB_TOKEN (gh api).
# Default/Fehler -> "de" (fail-safe).
set -uo pipefail
REPO="${1:-}"; PR="${2:-}"
[ -z "$REPO" ] || [ -z "$PR" ] && { echo de; exit 0; }

# 1) .codemole.yml-Override (lang: de|en) — deterministisch, schlägt die Heuristik
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OV="$(python3 "$DIR/resolve-profile.py" "${REPO_DIR:-.}" "$REPO" 2>/dev/null | python3 -c '
import sys, json
try:
    o = json.load(sys.stdin).get("options") or {}
except Exception:
    o = {}
v = str(o.get("lang", "")).strip().lower()
print(v if v in ("de", "en") else "")' 2>/dev/null)"
[ -n "$OV" ] && { echo "$OV"; exit 0; }

# 2) Heuristik auf PR-Titel + Beschreibung
TXT="$(gh api "repos/$REPO/pulls/$PR" --jq '(.title // "") + " " + (.body // "")' 2>/dev/null | head -c 4000)"
[ -z "$TXT" ] && { echo de; exit 0; }
printf '%s' "$TXT" | python3 -c '
import sys, re
t = sys.stdin.read().lower()
words = set(re.findall(r"[a-zäöüß]+", t))
de = {"der","die","das","und","nicht","mit","für","wird","ist","ein","eine","im","auf","bei","nach","wenn","damit","wurde","werden","sollte","kann","beim","vom","zum","zur","aus","auch","noch","schon","gegen","ohne","über","wie","dann","hier","neue","neuer"}
en = {"the","and","with","for","this","that","from","are","was","were","will","should","can","when","after","before","into","been","also","only","which","while","because","new","fix","fixes","adds","added","removes","update","updated","change","changed"}
umlauts = len(re.findall(r"[äöüß]", t))
de_score = len(words & de) + umlauts * 3
en_score = len(words & en)
print("en" if en_score > de_score else "de")
'
