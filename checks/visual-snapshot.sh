#!/bin/bash
# hermes-work-commons · Visual-Snapshot Spec-Matcher
# Matched Specs aus dem PR-Diff (3-stufig: direkt, Block-Default, transitive)
# Die eigentliche Playwright-Ausführung läuft als separater Step im
# Consumer-Workflow (siehe jumo.yml → visual-snapshot Step).
set -euo pipefail

cd "$GITHUB_WORKSPACE"

PR_NUMBER="${PR_NUMBER:-${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}}"
[ -z "$PR_NUMBER" ] && {
  echo "::error::PR_NUMBER nicht gesetzt"
  {
    echo "status=skip"
    echo "detail=Kein PR-Kontext"
  } >> "$GITHUB_OUTPUT"
  exit 0
}

# Spec-Roots aus .hermes-work.yml
if [ -f .hermes-work.yml ]; then
  SPEC_DIRS=$(yq -r '.visual.spec_dirs[]?' .hermes-work.yml 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi
SPEC_DIRS="${SPEC_DIRS:-visual-styleguide,test/visual}"

# Block-Roots
BLOCK_ROOTS=$(yq -r '.visual.block_roots[]?' .hermes-work.yml 2>/dev/null | tr '\n' ',' | sed 's/,$//')
BLOCK_ROOTS="${BLOCK_ROOTS:-blocks,patterns/atoms,patterns/molecules,patterns/organisms}"

# Helper: Pattern zu Regex
dir_to_re() {
  local dir="$1"
  dir="${dir%/}"
  echo "^${dir}/"
}

# PR-Files holen
mapfile -t PR_FILES < <(gh pr diff "$PR_NUMBER" --name-only 2>/dev/null | sort -u)

# Specs einsammeln
declare -A ALL_SPECS
for spec_dir in ${SPEC_DIRS//,/ }; do
  [ -d "$spec_dir" ] || continue
  while IFS= read -r f; do
    ALL_SPECS["$f"]=1
  done < <(find "$spec_dir" -name '*.spec.js' -type f 2>/dev/null)
done

if [ ${#ALL_SPECS[@]} -eq 0 ]; then
  {
    echo "status=skip"
    echo "detail=Keine Visual-Specs gefunden (spec_dirs: $SPEC_DIRS)"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# Berührte Block-Names aus PR-Files
declare -A BLOCK_NAMES
for f in "${PR_FILES[@]}"; do
  for root in ${BLOCK_ROOTS//,/ }; do
    if [[ "$f" =~ ^${root}/([^/]+)/ ]]; then
      BLOCK_NAMES["${BASH_REMATCH[1]}"]=1
      break
    fi
  done
done

# Stufe 1: direkter Match
declare -A MATCHED
direct_count=0
for spec in "${!ALL_SPECS[@]}"; do
  for f in "${PR_FILES[@]}"; do
    [ "$spec" = "$f" ] && { MATCHED["$spec"]="direct"; direct_count=$((direct_count+1)); break; }
  done
done

# Stufe 2: Block-Default
block_count=0
for spec in "${!ALL_SPECS[@]}"; do
  [ -n "${MATCHED[$spec]:-}" ] && continue
  for bn in "${!BLOCK_NAMES[@]}"; do
    if [[ "$spec" =~ /${bn}/ ]] || [[ "$spec" =~ /${bn%?}\. ]]; then
      MATCHED["$spec"]="block"
      block_count=$((block_count+1))
      break
    fi
  done
done

# Stufe 3: transitive via block-deps.json (falls vorhanden)
transitive_count=0
if [ -f block-deps.json ] && [ ${#BLOCK_NAMES[@]} -gt 0 ]; then
  # Node-Helper laden (liefert transitive Konsumenten)
  ACTION_PATH="${ACTION_PATH:-$GITHUB_ACTION_PATH}"
mapfile -t TRANSITIVE_CHAINS < <(node "$ACTION_PATH/scripts/visual-transitive.js" \
    "${BLOCK_NAMES[@]}" 2>/dev/null) || true
  for chain in "${TRANSITIVE_CHAINS[@]}"; do
    via="${chain%%->*}"
    consumer="${chain##*->}"
    [[ "$via" == "$consumer" ]] && continue
    for spec in "${!ALL_SPECS[@]}"; do
      [ -n "${MATCHED[$spec]:-}" ] && continue
      if [[ "$spec" =~ /${consumer}/ ]]; then
        MATCHED["$spec"]="transitive:${via}->${consumer}"
        transitive_count=$((transitive_count+1))
      fi
    done
  done
fi

total=${#MATCHED[@]}
# Details bauen
chain_str=""
if [ ${#MATCHED[@]} -gt 0 ]; then
  seen_chains=""
  for spec in "${!MATCHED[@]}"; do
    m="${MATCHED[$spec]}"
    if [[ "$m" == transitive:* ]]; then
      chain="${m#transitive:}"
      seen_chains+="$chain,"
    fi
  done
  seen_chains="${seen_chains%,}"
  [ -n "$seen_chains" ] && chain_str=" (via $seen_chains)"
fi

listing=""
if [ "$total" -le 12 ]; then
  listing=": $(printf '%s\n' "${!MATCHED[@]}" | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
else
  first10=$(printf '%s\n' "${!MATCHED[@]}" | head -10 | tr '\n' ',' | sed 's/,$//;s/,/, /g')
  listing=": $first10, …(+$(($total-10)) weitere)"
fi

detail="${total} Spec(s) [${direct_count} direkt, ${block_count} Block, ${transitive_count} transitiv]${chain_str}${listing}"

if [ "$total" -eq 0 ]; then
  {
    echo "status=warn"
    echo "detail=Keine Specs gematcht — geänderte Blocks haben keinen Visual-Test"
  } >> "$GITHUB_OUTPUT"
else
  {
    echo "status=pass"
    echo "detail=$detail"
  } >> "$GITHUB_OUTPUT"
fi
exit 0