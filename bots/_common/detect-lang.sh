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

# 1b) Serverseitige Vorgabe je Owner oder Owner/Repo:
#     /etc/hermes-work-app/lang-defaults.json  {"JUMO-GmbH-Co-KG": "de", "own/repo": "en"}
# Noetig, weil die Heuristik unten prinzipiell raten muss — bei einem Projekt, dessen
# Sprache feststeht, will man nicht raten. Und im Kunden-Repo koennen wir keine
# .codemole.yml ablegen, also gehoert die Vorgabe auf unsere Seite.
DEF="$(REPO="$REPO" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ.get("HERMES_APP_CONF", "/etc/hermes-work-app") + "/lang-defaults.json"))
except Exception:
    sys.exit(0)
r = os.environ["REPO"]
v = m.get(r) or m.get(r.split("/")[0]) or ""
print(v if str(v).lower() in ("de", "en") else "")' 2>/dev/null)"
[ -n "$DEF" ] && { echo "$DEF"; exit 0; }

# 2) Heuristik auf PR-Titel + Beschreibung
TXT="$(gh api "repos/$REPO/pulls/$PR" --jq '(.title // "") + " " + (.body // "")' 2>/dev/null | head -c 4000)"
[ -z "$TXT" ] && { echo de; exit 0; }
printf '%s' "$TXT" | python3 -c '
import sys, re
t = sys.stdin.read().lower()
# URLs und Template-Label-Zeilen raus: in JUMO-PRs steht "Before-URL/After-URL/Fix <link>"
# als BOILERPLATE — die drei Woerter kippten die Wertung auf "en", obwohl der
# Fliesstext deutsch war (PR #777: en 3 vs de 2, allein wegen after/before/fix).
t = re.sub(r"https?://\S+", " ", t)
t = re.sub(r"(?m)^\s*[-*]?\s*(before|after|fix|fixes|author|ticket|url|preview|test)\b\s*[-:–].*$", " ", t)
words = set(re.findall(r"[a-zäöüß]+", t))
de = {"der","die","das","und","nicht","mit","für","wird","ist","ein","eine","im","auf","bei","nach","wenn","damit","wurde","werden","sollte","kann","beim","vom","zum","zur","aus","auch","noch","schon","gegen","ohne","über","wie","dann","hier","neue","neuer",
      # ergaenzt: fehlten in echten JUMO-PRs und liessen deutschen Text als englisch gelten
      "den","dem","des","hat","haben","jetzt","neuen","neues","wurden","sind","sich","oder","aber","sowie","statt","mehr","nur","kein","keine","jede","jeder","alle","seite","seiten","wegen","bereits","dadurch","somit","dabei","muss","müssen","soll","sollen","angelegt","umgestellt","hinzugefügt","entfernt","geändert","behoben"}
en = {"the","and","with","for","this","that","from","are","was","were","will","should","can","when","after","before","into","been","also","only","which","while","because","new","fix","fixes","adds","added","removes","update","updated","change","changed"}
umlauts = len(re.findall(r"[äöüß]", t))
de_score = len(words & de) + umlauts * 3
en_score = len(words & en)
# Knapper Vorsprung reicht nicht: die Heuristik raet, und ein Fehlgriff faellt in
# einem deutschen Kundenprojekt staerker auf als umgekehrt -> "en" braucht Abstand 2.
print("en" if en_score >= de_score + 2 else "de")
'
