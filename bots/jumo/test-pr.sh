#!/bin/bash
# hermes-work — Wrapper für den jumo-testing-Runner.
# Setzt Token (aus geschützter Datei) + Repo-Dir und ruft run.js.
# Usage: test-pr.sh <branch> <pr> [base=dev] [mode=collect]
set -euo pipefail
export GITHUB_TOKEN="$(cat /opt/jumo-testing/.token)"
export REPO_DIR=/opt/jumo-cms
exec node /opt/jumo-testing/run.js "$@"
