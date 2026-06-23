#!/bin/bash
# hermes-work-commons · AEM-spezifische statische Scans
# - Framework-Imports (React/Vue/jQuery) verboten in AEM-EDS
# - outline:none verboten (WCAG)
# - JS-Bundle-Delta Warnung
set -euo pipefail

PR_NUMBER="${PR_NUMBER:-${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}}"
BASE_REF="${BASE_REF:-${GITHUB_BASE_REF:-main}}"

if [ -z "$PR_NUMBER" ]; then
  echo "::error::PR_NUMBER nicht gesetzt"
  {
    echo "status=skip"
    echo "detail=Kein PR-Kontext"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# Diff gegen base
mapfile -t DIFF_LINES < <(gh pr diff "$PR_NUMBER" 2>/dev/null)

current_file=""
files_to_scan=()

for line in "${DIFF_LINES[@]}"; do
  if [[ "$line" =~ ^\+\+\+\ b/(.+) ]]; then
    current_file="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^--- ]]; then
    :
  elif [ -n "$current_file" ]; then
    case "$current_file" in
      *.js|*.css) files_to_scan+=("$current_file") ;;
    esac
    current_file=""
  fi
done

# Dedup
mapfile -t FILES < <(printf '%s\n' "${files_to_scan[@]}" | sort -u)

if [ ${#FILES[@]} -eq 0 ]; then
  {
    echo "status=skip"
    echo "detail=Keine JS/CSS-Änderungen"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# .hermes-work.yml AEM-Config
outline_exc=false
if [ -f .hermes-work.yml ]; then
  val=$(yq -r '.aem.outline_none_exception // false' .hermes-work.yml 2>/dev/null || echo "false")
  [ "$val" = "true" ] && outline_exc=true
fi

issues=()
warns=()
bundle_delta=0

framework_re='\b(import\s+React|from\s+['"'"'"]react['"'"'"]|import\s+Vue|from\s+['"'"'"]vue['"'"'"]|from\s+['"'"'"]jquery['"'"'"]|import\s+\$)'

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  case "$f" in
    *.js)
      # Framework-Import-Check auf HINZUGEFÜGTEN Zeilen (Prefix '+' minus '+++')
      added=$(gh pr diff "$PR_NUMBER" --path "$f" 2>/dev/null | grep -E '^\+' | grep -v '^+++' || true)
      if echo "$added" | grep -nE "$framework_re" >/dev/null 2>&1; then
        hits=$(echo "$added" | grep -nE "$framework_re" | head -3)
        while IFS= read -r hit; do
          issues+=("Framework-Import in $f: $(echo "$hit" | sed 's/^+//')")
        done <<< "$hits"
      fi
      # Bundle-Delta: Summe der Hinzufügungen
      adds=$(echo "$added" | grep -cE '^\+' || echo 0)
      bundle_delta=$(( bundle_delta + adds * 80 ))   # grobe Schätzung
      ;;
    *.css)
      if [ "$outline_exc" = false ]; then
        added=$(gh pr diff "$PR_NUMBER" --path "$f" 2>/dev/null | grep -E '^\+' | grep -v '^+++' || true)
        if echo "$added" | grep -nE 'outline:\s*none' >/dev/null 2>&1; then
          issues+=("outline:none in $f (WCAG-Verstoß)")
        fi
      fi
      ;;
  esac
done

# Bundle-Warnung > 50KB
if [ "$bundle_delta" -gt 51200 ]; then
  delta_kb=$(( bundle_delta / 1024 ))
  warns+=("JS-Bundle ~${delta_kb}KB (Hinzufügungen)")
fi

if [ ${#issues[@]} -gt 0 ]; then
  detail=$(printf '%s\n' "${issues[@]}" | head -10)
  {
    echo "status<<EOF"
    echo "fail"
    echo "EOF"
    echo "detail<<EOF"
    echo "$detail"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
  echo "::error::AEM-Static-Scans: ${#issues[@]} Issues"
  exit 0
fi

if [ ${#warns[@]} -gt 0 ]; then
  {
    echo "status<<EOF"
    echo "warn"
    echo "EOF"
    echo "detail<<EOF"
    echo "${warns[*]}"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
  echo "::notice::AEM-Static-Scans: ${warns[*]}"
  exit 0
fi

{
  echo "status=pass"
  echo "detail=Keine AEM-Statik-Probleme"
} >> "$GITHUB_OUTPUT"
exit 0