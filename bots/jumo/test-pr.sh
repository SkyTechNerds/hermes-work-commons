#!/bin/bash
# hermes-work — JUMO-Bot-Wrapper.
# Setzt Token via load-token.sh + Repo-Dir und ruft run.js.
# Usage: test-pr.sh <branch> <pr> [base=dev] [mode=collect]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Vorgegebenes Env-Token (z. B. App-Installation-Token) hat Vorrang; sonst JUMO-PAT.
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="$(cat /etc/hermes-discord-listener/jumo.token)"
fi
# shellcheck source=../_common/load-token.sh
source "$SCRIPT_DIR/../_common/load-token.sh"

export REPO_DIR="${REPO_DIR:-/opt/jumo-cms}"
exec node "$SCRIPT_DIR/run.js" "$@"
