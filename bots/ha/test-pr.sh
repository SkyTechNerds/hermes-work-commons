#!/bin/bash
# hermes-work — HA-Config Wrapper: delegiert an den generischen Check-Runner.
# (Der frühere Monolith hier hatte eine Shell-Injection über Diff-Dateinamen in
#  add_check und ist vollständig durch _common/run-checks.sh + Module ersetzt.)
# Usage: test-pr.sh <pr> <branch> [base=main] [mode=collect]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common/load-token.sh
source "$SCRIPT_DIR/../_common/load-token.sh"

PR="$1"; BRANCH="$2"; BASE="${3:-main}"; MODE="${4:-collect}"
export REPO="${REPO:-SkyTechNerds/homeassistant-config}"
export REPO_DIR="${REPO_DIR:-/opt/ha-config-workdir}"

RMODE=post; [ "$MODE" = "dry" ] && RMODE=dry
exec bash "$SCRIPT_DIR/../_common/run-checks.sh" "$REPO" "$PR" "$BRANCH" "$BASE" "$RMODE"
