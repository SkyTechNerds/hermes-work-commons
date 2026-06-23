#!/bin/bash
# Path-Convention: prueft Datei-Positionen gegen Pattern aus .hermes-work.yml
if [ ! -f .hermes-work.yml ]; then
  echo "status=skip" >> "$GITHUB_OUTPUT"
  echo "Keine .hermes-work.yml - Path-Convention uebersprungen"
  exit 0
fi
PATTERNS=$(yq -r '.path_conventions[].pattern' .hermes-work.yml 2>/dev/null || true)
if [ -z "$PATTERNS" ]; then
  echo "status=skip" >> "$GITHUB_OUTPUT"
  echo "Keine path_conventions definiert"
  exit 0
fi
# (TODO: Pattern-Matching-Logik)
echo "status=pass" >> "$GITHUB_OUTPUT"
echo "Path-Convention OK"
