#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")"
exec node lighthouse.js "$@"
