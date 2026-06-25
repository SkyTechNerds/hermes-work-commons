#!/bin/bash
# hermes-work — JUMO-Bot-Wrapper.
# Setzt Token via load-token.sh + Repo-Dir und ruft run.js.
# Usage: test-pr.sh <branch> <pr> [base=dev] [mode=collect]
set -uo pipefail

# Token aus BW / Env / Cache laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GH_TOKEN="$(cat /etc/hermes-discord-listener/jumo.token)"  # JUMO-PAT fuer run.js
# shellcheck source=_common/load-token.sh
source "$SCRIPT_DIR/../_common/load-token.sh"

export REPO_DIR="${REPO_DIR:-/opt/jumo-cms}"
exec node "$SCRIPT_DIR/run.js" "$@"
