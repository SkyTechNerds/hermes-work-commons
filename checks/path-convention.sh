#!/bin/bash
# Path-Convention: prueft Datei-Pfade gegen Pattern aus .hermes-work.yml
if [ ! -f .hermes-work.yml ]; then
  echo "status=skip" >> "$GITHUB_OUTPUT"
  echo "Keine .hermes-work.yml - Path-Convention uebersprungen"
  exit 0
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "status=skip" >> "$GITHUB_OUTPUT"
  echo "yq nicht installiert - Path-Convention uebersprungen"
  exit 0
fi

PATTERNS=$(yq -r '.path_conventions[].pattern' .hermes-work.yml 2>/dev/null)
if [ -z "$PATTERNS" ]; then
  echo "status=skip" >> "$GITHUB_OUTPUT"
  echo "Keine path_conventions definiert"
  exit 0
fi

CHANGED=$(git diff --name-only "origin/${BASE_REF:-${GITHUB_BASE_REF:-main}}..HEAD")
VIOLATIONS=""

for pattern in $PATTERNS; do
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Konvertiere {a,b,c} zu [^/]+ und * zu .*
    regex=$(echo "$pattern" | sed -E 's/\{[a-z,]+\}/[^\/]+/g; s/\./\\./g; s/\*/.*/g')
    if ! echo "$file" | grep -qE "^${regex}$"; then
      VIOLATIONS="${VIOLATIONS}\n${file} (expected: ${pattern})"
    fi
  done <<< "$CHANGED"
done

if [ -n "$VIOLATIONS" ]; then
  echo "status=fail" >> "$GITHUB_OUTPUT"
  echo -e "Path-Violations:${VIOLATIONS}"
else
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "Alle Pfade konform"
fi
