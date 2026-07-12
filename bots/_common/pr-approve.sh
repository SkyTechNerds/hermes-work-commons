#!/bin/bash
# hermes-work — PR als "geprueft & sauber" markieren via formalem APPROVE-Review,
# bzw. ein altes Approve zuruecknehmen, wenn nicht mehr sauber. Idempotent (kein
# Doppel-Approve auf demselben Commit). Usage: pr-approve.sh <owner/repo> <pr> <approve|dismiss> [body...]
set -uo pipefail
[ "$#" -lt 3 ] && { echo "usage: pr-approve.sh <owner/repo> <pr> <approve|dismiss> [body]" >&2; exit 2; }
REPO="$1"; PR="$2"; MODE="$3"; shift 3; BODY="${*:-}"
BOT="the-codemole[bot]"

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

SHA="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null)" || { echo "pr-approve: head-SHA nicht ermittelbar" >&2; exit 1; }

if [ "$MODE" = "approve" ]; then
  # Schon fuer genau diesen Commit approved? -> nichts tun (kein Spam bei Re-Runs).
  N="$(gh api "repos/$REPO/pulls/$PR/reviews" \
        --jq "[.[] | select(.user.login==\"$BOT\" and .state==\"APPROVED\" and .commit_id==\"$SHA\")] | length" 2>/dev/null || echo 0)"
  if [ "${N:-0}" -gt 0 ]; then echo "APPROVE-SKIP: schon approved fuer $SHA"; exit 0; fi
  gh api -X POST "repos/$REPO/pulls/$PR/reviews" \
    -f event=APPROVE -f commit_id="$SHA" -f body="${BODY:-Alle Checks bestanden, KI-Review ohne Findings. — CodeMole}" \
    --jq '"APPROVED: " + (.html_url // "ok")'
elif [ "$MODE" = "dismiss" ]; then
  # Offene Bot-Approvals zuruecknehmen, damit kein stehengebliebenes Gruen bleibt.
  IDS="$(gh api "repos/$REPO/pulls/$PR/reviews" \
          --jq ".[] | select(.user.login==\"$BOT\" and .state==\"APPROVED\") | .id" 2>/dev/null || true)"
  [ -z "$IDS" ] && { echo "DISMISS-NOOP: kein offenes Approve"; exit 0; }
  for id in $IDS; do
    gh api -X PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
      -f message="${BODY:-Nicht mehr sauber — Approve zurueckgezogen.}" -f event=DISMISS \
      --jq '"DISMISSED: \(.id)"' 2>/dev/null || echo "dismiss-fail id=$id" >&2
  done
else
  echo "pr-approve: unbekannter Modus '$MODE'" >&2; exit 2
fi
