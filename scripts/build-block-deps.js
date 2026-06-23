#!/usr/bin/env node
/**
 * Block-Dependency-Index Builder.
 *
 * Scannt patterns/ und blocks/ nach Block-zu-Block-Beziehungen und schreibt
 * eine block-deps.json mit:
 *   - direct[A]   = Liste der Blöcke, die A direkt importiert oder aufruft
 *   - transitive[A] = direkte + indirekte Konsumenten (BFS, Tiefe 3)
 *
 * Wird vom Test-Runner (run.js) konsumiert, um bei einer Änderung an Block X
 * nicht nur X-Specs, sondern auch Specs aller Konsumenten von X zu triggern.
 * Begründung: Atoms wie button/text/image/link werden in vielen Organisms
 * eingebettet — eine Änderung an einem Atom kann visuelle Regressionen in
 * jedem Konsumenten verursachen, ohne dass der Konsument-Code geändert wurde.
 *
 * Aufruf:
 *   node build-block-deps.js [REPO_DIR] [OUT_FILE]
 *   REPO_DIR  default process.cwd()
 *   OUT_FILE  default <REPO_DIR>/block-deps.json
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// REPO_DIR und OUT_FILE strikt aus process.argv ableiten, damit der gleiche
// Code sowohl als CLI (node build-block-deps.js <repo> <out>) als auch als
// require() (build(repoDir, outFile)) funktioniert. Im Runner-Kontext ist
// process.argv[2] z. B. die PR-Nummer, also MUSS geprüft werden, ob es ein
// Pfad ist — sonst fallen wir auf process.cwd() bzw. <repo>/block-deps.json
// zurück.
function argIsPath(p) {
  return typeof p === 'string' && p.length > 0 && path.isAbsolute(p);
}
const REPO_DIR = argIsPath(process.argv[2]) ? process.argv[2] : process.cwd();
const OUT_FILE = argIsPath(process.argv[3]) ? process.argv[3] : path.join(REPO_DIR, 'block-deps.json');

const BLOCK_ROOTS = [
  'patterns/atoms',
  'patterns/molecules',
  'patterns/organisms',
  'blocks',
];

// Built-ins / häufige Helper-Funktionen die KEINE Blöcke sind.
const NON_BLOCK_FUNCS = new Set([
  'console', 'Math', 'Object', 'Array', 'Promise', 'Date', 'Number', 'String',
  'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'JSON', 'Error', 'Map', 'Set',
  'querySelector', 'querySelectorAll', 'addEventListener', 'getAttribute', 'setAttribute',
  'forEach', 'map', 'filter', 'reduce', 'find', 'findIndex', 'some', 'every',
  'includes', 'startsWith', 'endsWith', 'indexOf', 'slice', 'splice', 'push', 'pop',
  'shift', 'unshift', 'concat', 'join', 'split', 'replace', 'trim', 'toLowerCase',
  'toUpperCase', 'charAt', 'substring', 'substr', 'log', 'warn', 'error', 'info',
  'test', 'expect', 'describe', 'beforeEach', 'afterEach', 'beforeAll', 'afterAll',
  'fetch', 'response', 'request', 'route', 'continue', 'fulfill', 'abort',
  'waitFor', 'waitForSelector', 'click', 'fill', 'press', 'goto', 'locator',
  'import', 'require', 'export', 'return', 'if', 'else', 'for', 'while', 'switch',
  'try', 'catch', 'throw', 'new', 'this', 'self', 'window', 'document', 'globalThis',
  'setTimeout', 'setInterval', 'clearTimeout', 'clearInterval',
  'patternScreenshot', 'load', 'ready',
]);

function listBlockNames(repoDir = REPO_DIR) {
  const names = new Set();
  for (const root of BLOCK_ROOTS) {
    const abs = path.join(repoDir, root);
    if (!fs.existsSync(abs)) continue;
    for (const d of fs.readdirSync(abs, { withFileTypes: true })) {
      if (!d.isDirectory() || d.name.startsWith('_') || d.name.startsWith('.')) continue;
      names.add(d.name);
    }
  }
  return names;
}

/** Camel-Case: 'teaser-xl' → 'teaserXl', 'button' → 'button'. */
function toCamel(name) {
  return name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

/** Snake-Case: 'teaser-xl' → 'teaser_xl'. */
function toSnake(name) {
  return name.replace(/-/g, '_');
}

function blockDirOf(filePath) {
  const m = filePath.match(/\/(?:patterns\/(?:atoms|molecules|organisms)|blocks)\/([^/]+)\//);
  return m ? m[1] : null;
}

function resolveImport(srcFile, importPath) {
  if (!importPath.startsWith('.')) return null;
  const target = path.normalize(path.join(path.dirname(srcFile), importPath));
  return blockDirOf(target);
}

function build(repoDir = REPO_DIR, outFile = OUT_FILE) {
  // Im runner-Kontext via require() wird build(repoDir) explizit aufgerufen
  // und überschreibt die Modul-Konstanten — sonst landet die Datei in
  // process.cwd() statt im Repo.
  const _REPO_DIR = repoDir;
  const _OUT_FILE = outFile;
  const blocks = listBlockNames(_REPO_DIR);
  const directConsumers = new Map(); // tgt → Set(src)
  const directDeps = new Map();      // src → Set(tgt)
  let jsEdges = 0;
  let htmlEdges = 0;

  for (const root of BLOCK_ROOTS) {
    const abs = path.join(_REPO_DIR, root);
    if (!fs.existsSync(abs)) continue;
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) { walk(full); continue; }
        if (!entry.name.endsWith('.js')) continue;
        if (entry.name.startsWith('_')) continue; // _helpers etc.
        const srcBlock = blockDirOf(full);
        if (!srcBlock) continue;
        let content;
        try { content = fs.readFileSync(full, 'utf8'); } catch { continue; }

        // 1) ESM + Dynamic Imports
        const importRe = /import\s*(?:\(\s*)?(?:[^'"\n]+?from\s*)?['"]([^'"]+)['"]/g;
        for (const m of content.matchAll(importRe)) {
          const tgt = resolveImport(full, m[1]);
          if (tgt && tgt !== srcBlock) {
            if (!directConsumers.has(tgt)) directConsumers.set(tgt, new Set());
            directConsumers.get(tgt).add(srcBlock);
            if (!directDeps.has(srcBlock)) directDeps.set(srcBlock, new Set());
            directDeps.get(srcBlock).add(tgt);
            jsEdges++;
          }
        }

        // 2) HTML/Template-Block-Aufrufe (Function-Calls)
        for (const other of blocks) {
          if (other === srcBlock || NON_BLOCK_FUNCS.has(other)) continue;
          const cc = toCamel(other);
          const sn = toSnake(other);
          const patterns = [
            new RegExp(`\\b${escape(other)}\\s*\\(`),
            new RegExp(`\\b${escape(cc)}\\s*\\(`),
            new RegExp(`\\b${escape(sn)}\\s*\\(`),
          ];
          if (patterns.some((p) => p.test(content))) {
            if (!directConsumers.has(other)) directConsumers.set(other, new Set());
            directConsumers.get(other).add(srcBlock);
            if (!directDeps.has(srcBlock)) directDeps.set(srcBlock, new Set());
            directDeps.get(srcBlock).add(other);
            htmlEdges++;
          }
        }
      }
    };
    walk(abs);
  }

  // BFS für transitive Konsumenten
  function transitive(start, maxDepth = 3) {
    const seen = new Set();
    let frontier = new Set([start]);
    for (let d = 0; d < maxDepth; d++) {
      const next = new Set();
      for (const b of frontier) {
        for (const c of directConsumers.get(b) || []) {
          if (c !== start && !seen.has(c)) {
            seen.add(c);
            next.add(c);
          }
        }
      }
      if (next.size === 0) break;
      frontier = next;
    }
    return [...seen].sort();
  }

  const out = {
    generatedAt: new Date().toISOString(),
    stats: {
      blocks: blocks.size,
      directEdges: jsEdges + htmlEdges,
      jsEdges,
      htmlEdges,
    },
    // direct[A] = Blöcke, die A direkt konsumieren (= reverse dependency)
    direct: Object.fromEntries(
      [...directConsumers.entries()]
        .map(([tgt, srcs]) => [tgt, [...srcs].sort()])
        .sort(([a], [b]) => a.localeCompare(b))
    ),
    // transitive[A] = direkte + transitive Konsumenten (BFS)
    transitive: Object.fromEntries(
      [...directConsumers.keys()]
        .sort()
        .map((b) => [b, transitive(b)])
    ),
  };

  fs.writeFileSync(_OUT_FILE, JSON.stringify(out, null, 2) + '\n');
  return out;
}

function escape(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

if (require.main === module) {
  const result = build();
  console.log(`✓ ${OUT_FILE}`);
  console.log(`  ${result.stats.blocks} Blöcke, ${result.stats.directEdges} Edges (${result.stats.jsEdges} JS, ${result.stats.htmlEdges} HTML)`);
  console.log(`  Top-Konsumenten:`);
  const top = Object.entries(result.direct)
    .map(([b, c]) => [b, c.length])
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);
  for (const [b, n] of top) console.log(`    ${b}: ${n} direkte Konsumenten`);
}

module.exports = { build };
