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
BOT="the-codemole[bot]"
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

do_approve() {
  local sha; sha="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null)" || { echo "pr-approve: head-SHA nicht ermittelbar" >&2; return 1; }
  local n; n="$(gh api "repos/$REPO/pulls/$PR/reviews?per_page=100" \
        --jq "[.[] | select(.user.login==\"$BOT\" and .state==\"APPROVED\" and .commit_id==\"$sha\")] | length" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then echo "APPROVE-SKIP: schon approved fuer $sha"; return 0; fi
  gh api -X POST "repos/$REPO/pulls/$PR/reviews?per_page=100" \
    -f event=APPROVE -f commit_id="$sha" -f body="${BODY:-Alle Findings adressiert, Checks sauber. — CodeMole}" \
    --jq '"APPROVED: " + (.html_url // "ok")'
}

do_dismiss() {
  local ids; ids="$(gh api "repos/$REPO/pulls/$PR/reviews?per_page=100" \
          --jq ".[] | select(.user.login==\"$BOT\" and .state==\"APPROVED\") | .id" 2>/dev/null || true)"
  [ -z "$ids" ] && { echo "DISMISS-NOOP: kein offenes Approve"; return 0; }
  local id
  for id in $ids; do
    gh api -X PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
      -f message="${BODY:-Nicht mehr sauber — Approve zurueckgezogen.}" -f event=DISMISS \
      --jq '"DISMISSED: \(.id)"' 2>/dev/null || echo "dismiss-fail id=$id" >&2
  done
}

case "$MODE" in
  approve) do_approve ;;
  dismiss) do_dismiss ;;
  auto)
    # Offene (unaufgeloeste) Bot-Review-Threads zaehlen.
    OPEN="$(gh api graphql -f query="{repository(owner:\"$OWNER\",name:\"$NAME\"){pullRequest(number:$PR){reviewThreads(first:100){nodes{isResolved isOutdated comments(first:1){nodes{author{login}}}}}}}}" \
      --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .isOutdated==false and (.comments.nodes[0].author.login=="the-codemole"))] | length' 2>/dev/null || echo -1)"
    # Letzten Report-Kommentar holen.
    REPORT="$(gh api "repos/$REPO/issues/$PR/comments" \
      --jq '[.[] | select(.user.login=="the-codemole[bot]" and (.body|test("hermes-work:report")))] | last | .body' 2>/dev/null || true)"
    # ❌ = fehlgeschlagene Checks.
    FAILS="$(printf '%s' "$REPORT" | grep -c '❌' || true)"
    # ⚠️-Warns von Checks OHNE Inline-Thread (hacs/translations) blocken auch — sonst
    # waeren sie fuer auto unsichtbar (weder ❌ noch offener Thread). diff-size ist
    # informativ (grosser Diff) -> blockt NICHT; inline-Warns (entity-exists etc.)
    # laufen ueber die Thread-Zaehlung, damit Resolve-to-approve erhalten bleibt.
    WARN_BLOCK="$(printf '%s' "$REPORT" | grep '⚠️' | grep -cE '\*\*(hacs|translations)\*\*' || true)"
    echo "AUTO $REPO#$PR: offene Bot-Threads=$OPEN, ❌-Checks=$FAILS, Warn-Block=$WARN_BLOCK"
    if [ "${OPEN:--1}" = "0" ] && [ "${FAILS:-1}" -eq 0 ] && [ "${WARN_BLOCK:-1}" -eq 0 ]; then
      do_approve
    else
      do_dismiss   # noch offene Punkte -> ggf. stale Approve zuruecknehmen
    fi
    ;;
  *) echo "pr-approve: unbekannter Modus '$MODE'" >&2; exit 2 ;;
esac
