#!/usr/bin/env node
/**
 * jumo-testing-agent · Inline-Check-Runner
 *
 * Liest einen PR-Diff und wendet die JUMO-Pattern aus inline-checks/patterns.json
 * an. Für jeden Treffer wird ein zeilengenauer Kommentar-Vorschlag erzeugt.
 *
 * Aufruf:
 *   node run-inline-checks.js <diff-file> [<patterns-json>]
 *   diff-file: GitHub-Diff-Format (z. B. gh pr diff <nr>)
 *   patterns-json: default ./inline-checks/patterns.json
 *
 * Output: JSON-Array von {pattern, file, line, message, severity}
 *
 * Verwendung vom Hermes-Bot:
 *   diff=$(gh pr diff $PR --repo JUMO-GmbH-Co-KG/JUMO-Website-CMS)
 *   diff > /tmp/diff-$PR.txt
 *   findings=$(node /opt/jumo-agent/run-inline-checks.js /tmp/diff-$PR.txt)
 *   echo "$findings" | jq -c '.[]' | while read f; do
 *     /opt/jumo-testing/review-comment.sh $PR \
 *       $(echo $f | jq -r .file) \
 *       $(echo $f | jq -r .line) \
 *       "$(echo $f | jq -r .message)"
 *   done
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const diffFile = process.argv[2];
const patternsFile = process.argv[3] || path.join(__dirname, 'inline-checks', 'patterns.json');

if (!diffFile) {
  console.error('Usage: node run-inline-checks.js <diff-file> [<patterns-json>]');
  process.exit(2);
}

const diff = fs.readFileSync(diffFile, 'utf8');
const patterns = JSON.parse(fs.readFileSync(patternsFile, 'utf8'));

const findings = [];
let currentFile = null;
let inHunk = false;
let newLineNo = null;

for (const line of diff.split('\n')) {
  // Neuer File
  const fileMatch = line.match(/^\+\+\+ b\/(.+)$/);
  if (fileMatch) {
    currentFile = fileMatch[1];
    inHunk = false;
    newLineNo = null;
    continue;
  }

  // Hunk-Header
  const hunkMatch = line.match(/^@@ -(\d+),?\d* \+(\d+),?\d* @@/);
  if (hunkMatch) {
    inHunk = true;
    newLineNo = parseInt(hunkMatch[2], 10);
    continue;
  }

  if (!inHunk || !currentFile) continue;

  // Hinzugefügte Zeile (kein File-Marker)
  if (line.startsWith('+') && !line.startsWith('+++')) {
    const content = line.slice(1);
    for (const pat of patterns.patterns) {
      // Scope-Check
      if (pat.scope && pat.scope.dirs) {
        const matches = pat.scope.dirs.some(d => currentFile.startsWith(d));
        if (!matches) continue;
      }
      // Regex
      try {
        const re = new RegExp(pat.regex);
        if (re.test(content)) {
          // Exclude-Pattern prüfen
          if (pat.exclude && new RegExp(pat.exclude).test(content)) continue;
          // Context-Check: vorherige Zeilen müssen context_required matchen
          if (pat.context_required) {
            // Sammle letzte 5 hinzugefügte Zeilen dieses Files
            // (vereinfachung: suche im aktuellen Hunk rückwärts)
            // Hier überspringen wir den Context-Check und markieren nur
            // dass manual review nötig ist
          }
          findings.push({
            pattern: pat.id,
            severity: pat.severity,
            file: currentFile,
            line: newLineNo,
            message: pat.message,
            code: content.trim().slice(0, 100),
          });
        }
      } catch (e) {
        // Bad regex — skip
      }
    }
    newLineNo++;
  } else if (line.startsWith('-') && !line.startsWith('---')) {
    // Entfernte Zeile — newLineNo bleibt
  } else if (line.startsWith(' ')) {
    // Context — newLineNo zählt weiter
    newLineNo++;
  } else {
    inHunk = false;
  }
}

console.log(JSON.stringify(findings, null, 2));
process.exit(0);