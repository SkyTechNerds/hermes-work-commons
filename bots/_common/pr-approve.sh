#!/bin/bash
# hermes-work — PR als "geprueft & sauber" markieren via formalem APPROVE-Review,
# bzw. altes Approve zuruecknehmen. Idempotent (kein Doppel-Approve pro Commit).
# Modi:
#   approve  — bedingungslos approven (Aufrufer hat clean schon geprueft, Push-Pfad)
#   dismiss  — offene Bot-Approvals zuruecknehmen
#   auto     — SELBST bewerten: approve gdw. keine offenen Bot-Review-Threads UND
#              letzter Report ohne ❌; sonst stale Approve zuruecknehmen.
# Usage: pr-approve.sh <owner/repo> <pr> <approve|dismiss|auto> [body...]
set -uo pipefail
[ "$#" -lt 3 ] && { echo "usage: pr-approve.sh <owner/repo> <pr> <approve|dismiss|auto> [body]" >&2; exit 2; }
REPO="$1"; PR="$2"; MODE="$3"; shift 3; BODY="${*:-}"
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

# Env-Token (App-Installation) hat Vorrang; sonst PAT laden (wie review-comment.sh).
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  case "$REPO" in
    JUMO-GmbH-Co-KG/*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
    *)                 TOKFILE=/etc/hermes-discord-listener/hank.token ;;
  esac
  export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
elif [ -z "${GH_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

# Sprache der Bot-Meldungen an die PR-Sprache koppeln (detect-lang: Titel/Body-Heuristik
# + .codemole.yml lang:). CODEMOLE_LANG aus dem Env hat Vorrang, sonst selbst erkennen.
CM_LANG="${CODEMOLE_LANG:-$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect-lang.sh" "$REPO" "$PR" 2>/dev/null || echo de)}"
if [ "$CM_LANG" = "en" ]; then
  MSG_APPROVE="All checks passed, review clean. — CodeMole
<!-- codemole:bot -->"
  MSG_DISMISS="No longer clean — approval withdrawn.
<!-- codemole:bot -->"
else
  MSG_APPROVE="Alle Findings adressiert, Checks sauber. — CodeMole
<!-- codemole:bot -->"
  MSG_DISMISS="Nicht mehr sauber — Approve zurückgezogen.
<!-- codemole:bot -->"
fi

# Bot-Identitaet. Mit App-Installation-Token ist der Autor `the-codemole[bot]`;
# im PAT-Modus (Owner ohne App-Installation, z.B. JUMO) postet ein NORMALER User —
# dann muessen Idempotenz-, Thread- und Report-Abfragen auf DESSEN Login laufen,
# sonst zaehlt `auto` 0 offene Threads und approved trotz offener Findings.
# `gh api user` scheitert mit einem Installation-Token (403) -> Fallback = App-Bot.
# ACHTUNG: `gh api user` schreibt den 403-Fehlerkoerper als JSON auf STDOUT
# (nicht stderr) — ungeprueft landete der komplette JSON-Text in BOT und zersaegte
# spaeter den jq-Filter (Ergebnis -1 = "Thread-Zaehlung kaputt"). Deshalb streng
# validieren: GitHub-Logins bestehen nur aus [A-Za-z0-9-] (Bots zusaetzlich "[bot]").
_WHO="$(gh api user -q .login 2>/dev/null || true)"
if ! printf '%s' "${_WHO:-}" | grep -qE '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'; then _WHO=""; fi
if [ -n "${_WHO:-}" ] && [ "$_WHO" != "null" ]; then
  BOT="$_WHO"; BOT_GQL="$_WHO"
else
  BOT="the-codemole[bot]"; BOT_GQL="the-codemole"
fi

# Abschlusskommentar, wenn ein formales Approve unmoeglich ist (Bot == PR-Autor).
# Ohne ihn endet ein sauberer PR ohne jedes sichtbare Signal — der Haken fehlt ja.
# Upsert ueber eigenen Marker, damit bei jedem Lauf derselbe Kommentar aktualisiert
# statt ein neuer gepostet wird.
READY_MARK="<!-- hermes-work:ready -->"
post_ready() {
  local d note tmp
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ "$CM_LANG" = "en" ]; then
    note="**Review complete — ready to merge from the automation's side.**${BULLETS:-}"
    note="$note"$'\n\n'"<sub>No formal approval possible: the automation runs under the same account as the PR author.</sub>"
  else
    note="**Review abgeschlossen — aus Sicht der Automatisierung mergebar.**${BULLETS:-}"
    note="$note"$'\n\n'"<sub>Kein formales Approve möglich: die Automatisierung läuft unter demselben Account wie der PR-Autor.</sub>"
  fi
  tmp="$(mktemp)"; printf '%s\n%s\n' "$note" "<!-- codemole:bot -->" > "$tmp"
  if python3 "$d/post-comment.py" "$REPO" "$PR" "$tmp" "$READY_MARK" >/dev/null 2>&1; then
    READY_POSTED=1   # sonst raeumt der Aufrufer den Kommentar gleich wieder weg (s.u.)
    echo "READY-KOMMENTAR gesetzt"
  else
    echo "READY-KOMMENTAR fehlgeschlagen" >&2
  fi
  rm -f "$tmp"
}

# Gegenstueck: benennen, WAS den Abschluss blockiert. Vorher stand das nur als
# ❌-Zeile in der Check-Tabelle — auf einem langen PR faellt das schlicht nicht auf,
# und es fehlte die Aussage "deshalb ist hier noch nicht Schluss" (JUMO#786).
# Gleicher Marker wie der Fertig-Kommentar: es gibt IMMER genau einen Status-Kommentar,
# der zwischen "mergebar" und "noch offen" wechselt statt sich zu stapeln.
post_blocked() {
  local d body fails tmp; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # "❌ [**Name**](url) — Text"  ->  "- ❌ Name: Text"
  fails="$(printf '%s' "$REPORT" | grep '^❌' \
           | sed -E 's|^❌ \[\*\*([^*]*)\*\*\]\([^)]*\) — |- ❌ \1: |' | head -8)"
  if [ "$CM_LANG" = "en" ]; then
    body="**Not done yet — review still open.**"
    [ -n "$fails" ] && body="$body"$'\n'"$fails"
    [ "${OPEN:-0}" -gt 0 ] && body="$body"$'\n'"- ${OPEN} open finding(s) in the diff — please fix or reply in the thread"
    [ "${WARN_BLOCK:-0}" -gt 0 ] && body="$body"$'\n'"- ${WARN_BLOCK} blocking warning(s) in the report"
    body="$body"$'\n\n'"<sub>Once addressed, a push is enough — or comment \`@codemole recheck\`.</sub>"
  else
    body="**Noch nicht abgeschlossen — hier fehlt noch etwas.**"
    [ -n "$fails" ] && body="$body"$'\n'"$fails"
    [ "${OPEN:-0}" -gt 0 ] && body="$body"$'\n'"- ${OPEN} offene(s) Finding(s) im Diff — bitte beheben oder im Thread beantworten"
    [ "${WARN_BLOCK:-0}" -gt 0 ] && body="$body"$'\n'"- ${WARN_BLOCK} blockierende Warnung(en) im Report"
    body="$body"$'\n\n'"<sub>Nach dem Beheben genügt ein Push — oder als Kommentar \`@codemole recheck\`.</sub>"
  fi
  tmp="$(mktemp)"; printf '%s\n%s\n' "$body" "<!-- codemole:bot -->" > "$tmp"
  python3 "$d/post-comment.py" "$REPO" "$PR" "$tmp" "$READY_MARK" >/dev/null 2>&1 \
    && echo "STATUS-KOMMENTAR: noch offen" || echo "STATUS-KOMMENTAR fehlgeschlagen" >&2
  rm -f "$tmp"
}

# Nach einem echten Approve ist der Haken das Signal — dann muss der Status-Kommentar
# weg, sonst stuenden zwei Aussagen nebeneinander.
drop_ready() {
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$d/post-comment.py" "$REPO" "$PR" /dev/null "$READY_MARK" --delete >/dev/null 2>&1 || true
}

do_approve() {
  local sha; sha="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null)" || { echo "pr-approve: head-SHA nicht ermittelbar" >&2; return 1; }
  local n; n="$(gh api "repos/$REPO/pulls/$PR/reviews?per_page=100" \
        --jq "[.[] | select(.user.login==\"$BOT\" and .state==\"APPROVED\" and .commit_id==\"$sha\")] | length" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then echo "APPROVE-SKIP: schon approved fuer $sha"; return 0; fi
  local out rc
  out="$(gh api -X POST "repos/$REPO/pulls/$PR/reviews?per_page=100" \
    -f event=APPROVE -f commit_id="$sha" -f body="${BODY:-$MSG_APPROVE}" \
    --jq '"APPROVED: " + (.html_url // "ok")' 2>&1)"; rc=$?
  # GitHub verbietet das Approven EIGENER PRs. Im PAT-Modus ist der Bot ein
  # normaler User — ist er zugleich der PR-Autor, ist das kein Fehler, sondern
  # eine Systemgrenze: klar melden statt als Fehlschlag zu werten.
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "own pull request"; then
    echo "APPROVE-SKIP: $BOT ist selbst PR-Autor — GitHub erlaubt kein Self-Approve"
    post_ready   # ohne Haken waere sonst gar kein Abschluss sichtbar
    return 0
  fi
  printf '%s\n' "$out"
  return $rc
}

do_dismiss() {
  local ids; ids="$(gh api "repos/$REPO/pulls/$PR/reviews?per_page=100" \
          --jq ".[] | select(.user.login==\"$BOT\" and .state==\"APPROVED\") | .id" 2>/dev/null || true)"
  # gh schreibt Fehlerkoerper (404/5xx) als JSON auf STDOUT, nicht stderr. Ungefiltert
  # landete der Text in der Schleife und erzeugte Muell wie 'dismiss-fail id={"message"...'.
  # Deshalb nur echte IDs behalten.
  ids="$(printf '%s\n' "$ids" | grep -E '^[0-9]+$' || true)"
  [ -z "$ids" ] && { echo "DISMISS-NOOP: kein offenes Approve"; return 0; }
  local id
  for id in $ids; do
    gh api -X PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
      -f message="${BODY:-$MSG_DISMISS}" -f event=DISMISS \
      --jq '"DISMISSED: \(.id)"' 2>/dev/null || echo "dismiss-fail id=$id" >&2
  done
}

case "$MODE" in
  approve) do_approve ;;
  dismiss) do_dismiss ;;
  auto)
    # Review-Threads EINMAL holen und daraus offene UND erledigte zaehlen — die
    # erledigten braucht die Abschlussmeldung ("N Findings adressiert").
    GQL="$(gh api graphql -f query="{repository(owner:\"$OWNER\",name:\"$NAME\"){pullRequest(number:$PR){reviewThreads(first:100){nodes{isResolved isOutdated comments(first:1){nodes{author{login}}}}}}}}" 2>/dev/null || echo '{}')"
    OPEN="$(printf '%s' "$GQL" | jq "[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .isOutdated==false and (.comments.nodes[0].author.login==\"$BOT_GQL\"))] | length" 2>/dev/null || echo -1)"
    DONE_N="$(printf '%s' "$GQL" | jq "[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==true and (.comments.nodes[0].author.login==\"$BOT_GQL\"))] | length" 2>/dev/null || echo 0)"
    # Letzten Report-Kommentar holen.
    REPORT="$(gh api "repos/$REPO/issues/$PR/comments" \
      --jq "[.[] | select(.user.login==\"$BOT\" and (.body|test(\"hermes-work:report\")))] | last | .body" 2>/dev/null || true)"
    # ❌ = fehlgeschlagene Checks.
    FAILS="$(printf '%s' "$REPORT" | grep -c '❌' || true)"
    # ⚠️-Warns von Checks OHNE Inline-Thread (hacs/translations) blocken auch — sonst
    # waeren sie fuer auto unsichtbar (weder ❌ noch offener Thread). diff-size ist
    # informativ (grosser Diff) -> blockt NICHT; inline-Warns (entity-exists etc.)
    # laufen ueber die Thread-Zaehlung, damit Resolve-to-approve erhalten bleibt.
    WARN_BLOCK="$(printf '%s' "$REPORT" | grep '⚠️' | grep -cE '\*\*(hacs|translations)\*\*' || true)"
    echo "AUTO $REPO#$PR: offene Bot-Threads=$OPEN, ❌-Checks=$FAILS, Warn-Block=$WARN_BLOCK"
    if [ "${OPEN:--1}" = "0" ] && [ "${FAILS:-1}" -eq 0 ] && [ "${WARN_BLOCK:-1}" -eq 0 ]; then
      # Abschlussmeldung mit konkreten Zahlen statt nur "sauber" — sie ist der Text,
      # den GitHub unter "approved these changes" anzeigt, also der sichtbare Abschluss.
      OKN="$(printf '%s' "$REPORT" | grep -c '✅' || true)"
      SKN="$(printf '%s' "$REPORT" | grep -c '⚪' || true)"
      # Bullets separat halten: derselbe Befund wird einmal als Approve-Text und —
      # wenn GitHub kein Self-Approve zulaesst — als Abschlusskommentar gebraucht.
      BULLETS=""
      if [ "$CM_LANG" = "en" ]; then
        [ "${OKN:-0}" -gt 0 ] && BULLETS="$BULLETS"$'\n'"- Checks: ${OKN} passed, ${SKN} skipped, 0 failed"
        [ "${DONE_N:-0}" -gt 0 ] && BULLETS="$BULLETS"$'\n'"- ${DONE_N} finding(s) addressed, no open threads"
        [ "${DONE_N:-0}" -eq 0 ] && BULLETS="$BULLETS"$'\n'"- No findings, no open threads"
        SUM="**Approved — review complete.**${BULLETS}"
      else
        [ "${OKN:-0}" -gt 0 ] && BULLETS="$BULLETS"$'\n'"- Checks: ${OKN} grün, ${SKN} übersprungen, 0 fehlgeschlagen"
        [ "${DONE_N:-0}" -gt 0 ] && BULLETS="$BULLETS"$'\n'"- ${DONE_N} Finding(s) adressiert, keine offenen Punkte"
        [ "${DONE_N:-0}" -eq 0 ] && BULLETS="$BULLETS"$'\n'"- Keine Findings, keine offenen Punkte"
        SUM="**Freigegeben — Review abgeschlossen.**${BULLETS}"
      fi
      export BULLETS
      BODY="$SUM"$'\n'"<!-- codemole:bot -->"
      READY_POSTED=""
      if do_approve && [ -z "$READY_POSTED" ]; then
        drop_ready   # echter Haken gesetzt -> Status-Kommentar unnoetig
      fi
    else
      do_dismiss   # noch offene Punkte -> ggf. stale Approve zuruecknehmen
      post_blocked # ... und sichtbar sagen, WAS noch fehlt
    fi
    ;;
  *) echo "pr-approve: unbekannter Modus '$MODE'" >&2; exit 2 ;;
esac
