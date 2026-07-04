#!/bin/bash
# hermes-work — ha-soft-presence Wrapper: delegiert an den generischen Check-Runner.
# Usage: test-pr.sh <pr> <branch> [base=main] [mode=collect]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common/load-token.sh
source "$SCRIPT_DIR/../_common/load-token.sh"

PR="$1"; BRANCH="$2"; BASE="${3:-main}"; MODE="${4:-collect}"
export REPO="${REPO:-SkyTechNerds/ha-soft-presence}"
export REPO_DIR="${REPO_DIR:-/opt/ha-soft-presence-workdir}"

RMODE=post; [ "$MODE" = "dry" ] && RMODE=dry
exec bash "$SCRIPT_DIR/../_common/run-checks.sh" "$REPO" "$PR" "$BRANCH" "$BASE" "$RMODE"
