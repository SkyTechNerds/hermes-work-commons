#!/bin/bash
# hermes-work — erstellt/aktualisiert eine SCHEMA-konforme Wiki-Seite:
#   - YAML-Frontmatter automatisch (title/created/updated/type/tags/sources/confidence)
#   - haengt log.md-Eintrag an
#   - traegt in index.md ein (Sektion "## Neu (Agent)")
# Body kommt via stdin. Unprivileged-LXC-tauglich (smbclient).
# Usage: wiki-page.sh <type> <slug> "<title>" "<tag,tag,...>" [section]
#   type:    entity|concept|comparison|query|summary|reference
#   slug:    lowercase-hyphen, ohne .md
#   section: Resources (default) | concepts | Inbox | ...
set -uo pipefail
[ "$#" -lt 4 ] && { echo "usage: wiki-page.sh <type> <slug> <title> <tags-comma> [section]" >&2; exit 2; }
TYPE="$1"; SLUG="$2"; TITLE="$3"; TAGS="$4"; SECTION="${5:-Resources}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$SECTION/$SLUG.md"
DATE="$(date +%F)"
BODY="$(cat)"

# Schema-Pflicht: mind. 2 Wikilinks im Body
LINKS=$(printf '%s' "$BODY" | grep -oE '\[\[[^]]+\]\]' | wc -l | tr -d ' ')
if [ "$LINKS" -lt 2 ]; then
  echo "ABORT: nur $LINKS Wikilink(s) im Body — Schema verlangt mind. 2 [[...]]. Body ergaenzen." >&2
  exit 3
fi
case "$SLUG" in *[!a-z0-9-]*) echo "ABORT: slug muss lowercase-hyphen sein (a-z0-9-): $SLUG" >&2; exit 3;; esac

TAGYAML=$(printf '%s' "$TAGS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d; s/^/  - /')

# Falls Seite existiert: created-Datum erhalten
EXIST="$("$DIR/wiki-get.sh" "$DEST" 2>/dev/null)"
CREATED="$DATE"
if [ -n "$EXIST" ]; then
  C=$(printf '%s' "$EXIST" | grep -m1 '^created:' | sed 's/created:[[:space:]]*//')
  [ -n "$C" ] && CREATED="$C"
fi

TMP=$(mktemp)
{
  echo "---"
  echo "title: $TITLE"
  echo "created: $CREATED"
  echo "updated: $DATE"
  echo "type: $TYPE"
  echo "tags:"
  echo "$TAGYAML"
  echo "sources: []"
  echo "confidence: high"
  echo "---"
  echo ""
  printf '%s\n' "$BODY"
} > "$TMP"
"$DIR/wiki-put.sh" "$TMP" "$DEST" || { rm -f "$TMP"; exit 1; }
rm -f "$TMP"

# log.md anhaengen
ACT="create"; [ -n "$EXIST" ] && ACT="update"
LOGTMP=$(mktemp)
"$DIR/wiki-get.sh" log.md > "$LOGTMP" 2>/dev/null || true
printf '\n## [%s] %s | %s\n- Seite [[%s/%s|%s]] %s (hermes-work Agent).\n' \
  "$DATE" "$ACT" "$TITLE" "$SECTION" "$SLUG" "$TITLE" "$ACT" >> "$LOGTMP"
"$DIR/wiki-put.sh" "$LOGTMP" "log.md" >/dev/null 2>&1 && echo "log.md: ok"
rm -f "$LOGTMP"

# index.md (nur bei neuer Seite) unter "## Neu (Agent)"
if [ -z "$EXIST" ]; then
  IDXTMP=$(mktemp)
  "$DIR/wiki-get.sh" index.md > "$IDXTMP" 2>/dev/null || true
  grep -q '^## Neu (Agent)' "$IDXTMP" || printf '\n## Neu (Agent)\n' >> "$IDXTMP"
  printf -- '- [[%s/%s|%s]] — vom hermes-work Agent angelegt %s\n' "$SECTION" "$SLUG" "$TITLE" "$DATE" >> "$IDXTMP"
  "$DIR/wiki-put.sh" "$IDXTMP" "index.md" >/dev/null 2>&1 && echo "index.md: ok"
  rm -f "$IDXTMP"
fi

echo "WIKI-PAGE: $DEST ($ACT, $LINKS Wikilinks)"
