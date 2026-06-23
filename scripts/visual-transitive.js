#!/usr/bin/env node
/**
 * hermes-work-commons · Visual-Transitive Konsumenten
 * Liest block-deps.json und gibt für jeden Block die transitive Liste zurück.
 * Usage: node visual-transitive.js blockA blockB ...
 *   Output: "blockA->consumer1" pro Zeile
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEPS_FILE = path.join(process.cwd(), 'block-deps.json');
if (!fs.existsSync(DEPS_FILE)) process.exit(0);

let deps;
try {
  deps = JSON.parse(fs.readFileSync(DEPS_FILE, 'utf8'));
} catch {
  process.exit(0);
}

const transitive = deps.transitive || {};
const blocks = process.argv.slice(2);

const seen = new Set();
for (const b of blocks) {
  const consumers = transitive[b] || [];
  for (const c of consumers) {
    const key = `${b}->${c}`;
    if (!seen.has(key)) {
      seen.add(key);
      console.log(key);
    }
  }
}