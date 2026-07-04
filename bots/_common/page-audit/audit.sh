#!/bin/bash
# Wrapper für den Handler (run() spawnt bash). Usage: audit.sh <repo> <pr> <branch> <base>
cd "$(dirname "${BASH_SOURCE[0]}")"
exec node audit.js "$@"
