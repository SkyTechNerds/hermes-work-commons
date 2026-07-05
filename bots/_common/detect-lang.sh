#!/bin/bash
# hermes-work — detect-lang.sh <owner/repo> <pr>
# Erkennt die PR-Sprache (Titel + Beschreibung) und gibt "de" oder "en" aus.
# Heuristik: Umlaute/ß zählen stark für Deutsch; sonst Stopwort-Mehrheit. Default: de.
# Env: GH_TOKEN/GITHUB_TOKEN (für gh api). Fehler -> "de" (fail-safe, bisheriges Verhalten).
set -uo pipefail
REPO="${1:-}"; PR="${2:-}"
[ -z "$REPO" ] || [ -z "$PR" ] && { echo de; exit 0; }
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
