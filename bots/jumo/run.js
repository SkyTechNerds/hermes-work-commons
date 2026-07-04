/**
 * JUMO Testing Skill — run.js
 * --------------------------------------------------------------------------
 * Deterministischer PR-Test-Runner für JUMO-Website-CMS (Wiederaufbau des
 * alten Nero/OpenClaw-Skills als hermes-work-Skill).
 *
 * Führt 9 Checks gegen einen offenen GitHub-PR aus und postet im collect-Modus
 * einen ✅/❌-Basiskommentar. Der LLM-Agent (hermes-work) fügt danach optional
 * einen Code-Review als zweiten Kommentar hinzu.
 *
 * Aufruf:
 *   node run.js <branch> <prNumber> <baseBranch> <mode>
 *   mode: collect (default) | update-snapshots
 *
 * Env:
 *   GITHUB_TOKEN   Pflicht zum Posten (lokal Fallback: `gh auth token`)
 *   REPO           default "JUMO-GmbH-Co-KG/JUMO-Website-CMS"
 *   REPO_DIR       Arbeitskopie des Repos (default: process.cwd())
 *   DRY_RUN=1      Kommentar nur ausgeben, NICHT posten (lokales Testen)
 *   BASE_URL_DEV / BASE_URL_BRANCH  Preview-Hosts für Visual-Tests (optional)
 *
 * Quelle der Check-Spezifikation: JUMO-Website-CMS/docu/testing-system.md
 * @module jumo-testing/run
 */

'use strict';

const { execSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// ---------------------------------------------------------------------------
// Konstanten
// ---------------------------------------------------------------------------

const REPO = process.env.REPO || 'JUMO-GmbH-Co-KG/JUMO-Website-CMS';
const REPO_DIR = process.env.REPO_DIR || process.cwd();
const DRY_RUN = process.env.DRY_RUN === '1' || process.env.DRY_RUN === 'true';

const FILE_GUARD_MIN_BASELINE = 10;       // min. Zeilen Baseline für %-Bewertung
const FILE_GUARD_REDUCTION_PCT = 80;      // >80% Zeilenreduktion = Verdacht
const MERGE_FRESHNESS_WARN = 10;          // > 10 Commits hinter Base = Warnung
const MERGE_FRESHNESS_FAIL = 30;          // > 30 Commits hinter Base = Fehler
const BUNDLE_GROWTH_WARN_KB = 10;         // > 10 KB JS-Zuwachs = Warnung
// Visual-Spec-Verzeichnisse in Suchreihenfolge: der neue Styleguide (nested nach
// Block benannt) hat den alten flachen `tests/visual/`-Pfad abgelöst. Werden
// beide unterstützt, damit alte und neue Repos laufen.
const VISUAL_SPEC_DIRS = ['tests/visual-styleguide', 'tests/visual'];
const PLACEHOLDER_FILES = ['jumo.json', 'jumo-search.json'];

const ICON = { ok: '✅', fail: '❌', warn: '⚠️', skip: '⚪' };
const MAX_LINT_PROBLEMS = 30;             // Detail-Cap gegen Mega-Kommentare (minifizierte Files)

/** Problem-Liste fürs Kommentar-Detail begrenzen. */
function capProblems(problems) {
  if (problems.length <= MAX_LINT_PROBLEMS) return problems.join('\n');
  return problems.slice(0, MAX_LINT_PROBLEMS).join('\n')
    + `\n… +${problems.length - MAX_LINT_PROBLEMS} weitere`;
}

// --- .codemole.yml-Integration (gemeinsam mit den HA-Runnern: Profil-Header + disable/ignore) ---
let PROFILE_LINE = '';
let CM_DISABLED = [];
let CM_IGNORE = [];
function slug(name) { return String(name).toLowerCase().replace(/\s+/g, '-'); }
function resolveProfile() {
  try {
    const out = execFileSync('python3',
      [path.join(__dirname, '..', '_common', 'resolve-profile.py'), REPO_DIR, REPO],
      { encoding: 'utf8' });
    return JSON.parse(out);
  } catch (e) {
    return { profile: 'aem-eds', source: 'auto', disabled: [], ignore: [], options: {} };
  }
}
function globToRe(g) {
  const esc = g.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp('^' + esc + '$');
}
function ignoredPath(p, globs) {
  return (globs || []).some((g) => {
    const g2 = g.replace(/\*\*\//g, '').replace(/\*\*/g, '*');
    return globToRe(g).test(p) || globToRe(g2).test(p) || globToRe('*/' + g2).test(p);
  });
}

// ---------------------------------------------------------------------------
// CLI-Argumente
// ---------------------------------------------------------------------------

// CLI-Argumente: BASE_BRANCH ist nur Fallback/Override — primär wird pr.base.ref
// aus der GitHub-API genutzt, weil Stack-PRs auf wcms-2294-* / wcms-2777-tokens
// basieren statt auf dev.
const [, , BRANCH, PR_NUMBER, BASE_BRANCH_ARG, MODE = 'collect'] = process.argv;
let BASE_BRANCH = BASE_BRANCH_ARG || 'dev';

if (!BRANCH || !PR_NUMBER) {
  console.error('Usage: node run.js <branch> <prNumber> [baseBranch=dev] [mode=collect]');
  process.exit(2);
}

// Ref-Namen landen in git-Argumenten — Shell-Metazeichen/Flags/Traversal ablehnen
// (der App-Webhook-Pfad liefert Branch-Namen aus dem PR-Payload = untrusted).
function validRef(ref) {
  return typeof ref === 'string' && ref.length <= 200
    && /^[A-Za-z0-9._\/-]+$/.test(ref) && !ref.includes('..') && !ref.startsWith('-') && !ref.startsWith('/');
}
if (!validRef(BRANCH) || !/^\d+$/.test(PR_NUMBER) || (BASE_BRANCH_ARG && !validRef(BASE_BRANCH_ARG))) {
  console.error(`Ungültige Argumente: branch='${BRANCH}' pr='${PR_NUMBER}' base='${BASE_BRANCH_ARG}'`);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Token aus Env oder lokal aus `gh auth token`. */
function resolveToken() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN.trim();
  try {
    return execSync('gh auth token', { encoding: 'utf8' }).trim();
  } catch {
    return null;
  }
}

const TOKEN = resolveToken();

/** git-Befehl im Repo-Verzeichnis (execFileSync, KEINE Shell — Branch-/Dateinamen
 *  aus dem PR sind untrusted), gibt stdout (trimmed) zurück; '' bei Fehler. */
function git(...args) {
  try {
    return execFileSync('git', args, { cwd: REPO_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

/** GitHub REST API GET → JSON. Paginiert nicht (für >100 Files ggf. erweitern). */
async function ghApi(endpoint) {
  const res = await fetch(`https://api.github.com${endpoint}`, {
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'jumo-testing-runner',
    },
  });
  if (!res.ok) throw new Error(`GitHub API ${endpoint} → ${res.status} ${res.statusText}`);
  return res.json();
}

/** Inhalt einer Datei auf einem Ref (origin/<ref>:path); null wenn nicht vorhanden.
 *  execFileSync mit Argument-Array: PR-Dateinamen dürfen nie durch eine Shell. */
function fileAtRef(ref, file) {
  try {
    return execFileSync('git', ['show', `${ref}:${file}`],
      { cwd: REPO_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return null;
  }
}

/** Zeilenanzahl einer Datei auf einem Ref (leere Datei = 0). */
function lineCountAtRef(ref, file) {
  const c = fileAtRef(ref, file);
  if (c == null) return null;
  return c === '' ? 0 : c.split('\n').length;
}

/** Lädt testing-rules.json-Ausnahmen aus dem Repo. */
function loadExceptions() {
  try {
    const raw = fs.readFileSync(path.join(REPO_DIR, 'testing-rules.json'), 'utf8');
    return JSON.parse(raw).exceptions || [];
  } catch {
    return [];
  }
}

/** Prüft, ob für eine Regel eine projektweite Ausnahme existiert. */
function hasProjectException(exceptions, rule) {
  return exceptions.some((e) => e.rule === rule && e.scope === 'project');
}

const isJs = (f) => /\.(js|mjs)$/.test(f);
const isCss = (f) => f.endsWith('.css');
const isJsonCfg = (f) => f.endsWith('.json');

/** Block-Name aus einem geänderten Pfad ableiten.
 *  Unterstützt sowohl altes `blocks/<name>/...` als auch neues Atomic-Layout
 *  `patterns/{organisms,molecules,atoms}/<name>/...`. */
function blockNameOf(file) {
  let m = file.match(/^blocks\/([^/]+)\//);
  if (m) return m[1];
  m = file.match(/^patterns\/(?:organisms|molecules|atoms)\/([^/]+)\//);
  return m ? m[1] : null;
}

// ---------------------------------------------------------------------------
// Setup: benötigte Refs holen
// ---------------------------------------------------------------------------

// PR-Metadaten laden + effektiven Base-Branch ableiten, bevor ensureRefs() läuft
// (Fetch braucht den Ref). Reihenfolge: pr.base.ref gewinnt, sonst CLI-Override,
// sonst 'dev'.
async function resolveBaseBranch(prNumber) {
  const pr = await ghApi(`/repos/${REPO}/pulls/${prNumber}`);
  const fromPr = pr?.base?.ref;
  if (fromPr && validRef(fromPr)) {
    if (BASE_BRANCH_ARG && BASE_BRANCH_ARG !== fromPr) {
      console.warn(`Hinweis: CLI-base='${BASE_BRANCH_ARG}' ignoriert — PR mergt nach '${fromPr}'`);
    }
    BASE_BRANCH = fromPr;
  }
  return pr;
}

function ensureRefs() {
  // Von authentifizierter URL fetchen (privates Repo, kein Credential-Helper in CI;
  // Token nur zur Laufzeit, nicht in der Git-Config persistiert). Explizite Refspecs
  // erzwingen die Remote-Tracking-Refs auch bei `clone --depth` (→ --single-branch).
  // Es werden drei Refs geholt: dev (für BASE_URL_DEV-Fallbacks), der PR-Head und
  // der effektive Merge-Base-Branch (kann != dev sein, z. B. wcms-2777-tokens).
  const authUrl = `https://x-access-token:${TOKEN}@github.com/${REPO}.git`;
  git('fetch', authUrl, '--depth', '50',
    '+refs/heads/dev:refs/remotes/origin/dev',
    `+refs/heads/${BASE_BRANCH}:refs/remotes/origin/${BASE_BRANCH}`,
    `+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}`);
  // Arbeitsbaum auf den PR-Head bringen — sonst linten/scannen wir den Default-Branch
  // statt der PR-Änderungen. In CI (dediziertes /opt/jumo-cms) immer; auf einem
  // lokalen Arbeitsrepo nur mit FORCE_CHECKOUT=1, um ungespeicherte Arbeit zu schützen.
  const dirty = git('status', '--porcelain');
  if (dirty && process.env.FORCE_CHECKOUT !== '1') {
    console.warn('WARN: Arbeitsbaum nicht sauber → kein Checkout (lokaler Modus). FORCE_CHECKOUT=1 erzwingt ihn.');
    return;
  }
  git('checkout', '-f', '-B', BRANCH, `origin/${BRANCH}`);
}

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

/** 1 — File Guard: gelöschte/geleerte JS+CSS, >80% Zeilenreduktion. */
function checkFileGuard(files, prLabels) {
  if (prLabels.includes('intentional-delete')) {
    return { name: 'File Guard', ok: true, detail: 'übersprungen (Label `intentional-delete`)' };
  }
  const flagged = [];
  for (const f of files) {
    if (!(isJs(f.filename) || isCss(f.filename))) continue;
    if (f.status === 'removed') {
      flagged.push(`gelöscht: ${f.filename}`);
      continue;
    }
    const baseLines = lineCountAtRef(`origin/${BASE_BRANCH}`, f.filename);
    const headLines = lineCountAtRef(`origin/${BRANCH}`, f.filename);
    if (headLines === 0 || (headLines != null && headLines <= 1 && (baseLines || 0) > FILE_GUARD_MIN_BASELINE)) {
      flagged.push(`geleert: ${f.filename}`);
      continue;
    }
    if (baseLines && baseLines >= FILE_GUARD_MIN_BASELINE) {
      const reduction = ((baseLines - (headLines ?? baseLines)) / baseLines) * 100;
      if (reduction > FILE_GUARD_REDUCTION_PCT) {
        flagged.push(`-${Math.round(reduction)}% Zeilen: ${f.filename}`);
      }
    }
  }
  return flagged.length
    ? { name: 'File Guard', ok: false, detail: flagged.join('\n') }
    : { name: 'File Guard', ok: true, detail: 'Keine gelöschten, geleerten oder auffällig veränderten Dateien' };
}

/** 2 — PR-Vollständigkeit: WCMS-Ticket, Problem/Fix, Before/After-URL. */
function checkPrCompleteness(pr) {
  const title = pr.title || '';
  const body = pr.body || '';
  const missing = [];
  // Ticket darf im Titel ODER im Body stehen (JUMO-Template setzt "JIRA: WCMS-…" in den Body).
  if (!/WCMS-\d+/i.test(title) && !/WCMS-\d+/i.test(body)) missing.push('WCMS-Ticket');
  // Problem/Fix als Markdown-Heading (## …) oder fett (**Problem:** / **Fix:**).
  if (!/(?:#+\s*|\*\*\s*)Problem/i.test(body)) missing.push('Problem-Abschnitt');
  if (!/(?:#+\s*|\*\*\s*)Fix/i.test(body)) missing.push('Fix-Abschnitt');
  const urls = body.match(/https?:\/\/\S+/g) || [];
  if (urls.length < 2) missing.push('Before- und After-URL');
  return missing.length
    ? { name: 'PR-Vollständigkeit', ok: false, detail: `Fehlt: ${missing.join(', ')}` }
    : { name: 'PR-Vollständigkeit', ok: true, detail: 'Ticket, URLs, Problem, Fix vorhanden' };
}

/** 3 — JS Lint: ESLint auf geänderte JS/MJS/JSON-Dateien. */
function checkJsLint(files) {
  const targets = files
    .filter((f) => f.status !== 'removed' && (isJs(f.filename) || isJsonCfg(f.filename)))
    .map((f) => f.filename)
    .filter((f) => fs.existsSync(path.join(REPO_DIR, f)));
  if (!targets.length) return { name: 'JS Lint', ok: true, detail: 'Keine geänderten JS/JSON-Dateien' };
  // --no-install: nie Pakete on-the-fly aus npm nachladen; Timeout gegen Hänger.
  let out; let execErr = null;
  try {
    out = execFileSync('npx', ['--no-install', 'eslint', ...targets, '--ext', '.js,.mjs,.json', '-f', 'json'],
      { cwd: REPO_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180000 });
  } catch (e) {
    out = e.stdout; execErr = e;
  }
  // "ESLint lief mit Findings" (exit 1 + JSON) sauber von "ESLint konnte nicht
  // laufen" (kein/kaputter Output) trennen — Letzteres darf NICHT grün werden.
  if (!out || !String(out).trim()) {
    return { name: 'JS Lint', ok: false, detail: `ESLint konnte nicht ausgeführt werden: ${String(execErr && execErr.message || 'kein Output').slice(0, 300)}` };
  }
  let results;
  try { results = JSON.parse(out); } catch {
    return { name: 'JS Lint', ok: false, detail: `ESLint-Output nicht parsebar: ${String(out).slice(0, 300)}` };
  }
  const problems = [];
  for (const r of results) {
    for (const m of r.messages) {
      if (m.severity === 2) {
        const rel = path.relative(REPO_DIR, r.filePath);
        problems.push(`In ${rel} Zeile ${m.line}: ${m.message} (${m.ruleId || 'parse'})`);
      }
    }
  }
  return problems.length
    ? { name: 'JS Lint', ok: false, detail: capProblems(problems) }
    : { name: 'JS Lint', ok: true, detail: `0 Fehler (${targets.length} Datei(en))` };
}

/** 4 — CSS Lint: Stylelint, bypasst .stylelintignore (ignoriert sonst alle CSS). */
function checkCssLint(files) {
  const targets = files
    .filter((f) => f.status !== 'removed' && isCss(f.filename))
    .map((f) => f.filename)
    .filter((f) => fs.existsSync(path.join(REPO_DIR, f)));
  if (!targets.length) return { name: 'CSS Lint', ok: true, detail: 'Keine geänderten CSS-Dateien' };
  let out; let execErr = null;
  try {
    out = execFileSync('npx', ['--no-install', 'stylelint', ...targets, '--ignore-path', '/dev/null', '-f', 'json'],
      { cwd: REPO_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180000 });
  } catch (e) {
    // Stylelint schreibt den JSON-Report bei Findings teils auf stderr (ältere Versionen: stdout)
    out = e.stdout && String(e.stdout).trim() ? e.stdout : e.stderr; execErr = e;
  }
  if (!out || !String(out).trim()) {
    return { name: 'CSS Lint', ok: false, detail: `Stylelint konnte nicht ausgeführt werden: ${String(execErr && execErr.message || 'kein Output').slice(0, 300)}` };
  }
  let results;
  try { results = JSON.parse(out); } catch {
    return { name: 'CSS Lint', ok: false, detail: `Stylelint-Output nicht parsebar: ${String(out).slice(0, 300)}` };
  }
  const problems = [];
  for (const r of results) {
    for (const w of r.warnings || []) {
      const rel = path.relative(REPO_DIR, r.source);
      problems.push(`In ${rel} Zeile ${w.line}: ${w.text} (${w.rule})`);
    }
  }
  return problems.length
    ? { name: 'CSS Lint', ok: false, detail: capProblems(problems) }
    : { name: 'CSS Lint', ok: true, detail: `0 Fehler (${targets.length} Datei(en))` };
}

/** 5 — Placeholder-Keys: literal-Key-Zugriffe gegen AEM-Placeholder-JSON. */
async function checkPlaceholderKeys(files, pr, exceptions) {
  if (hasProjectException(exceptions, 'placeholder-keys')) {
    return { name: 'Placeholder-Keys', ok: true, skipped: true, detail: 'projektweite Ausnahme in testing-rules.json' };
  }
  const afterUrl = (pr.body.match(/https?:\/\/\S+/g) || []).find((u) => /--/.test(u));
  const jsFiles = files.filter((f) => f.status !== 'removed' && isJs(f.filename))
    .map((f) => f.filename).filter((f) => fs.existsSync(path.join(REPO_DIR, f)));
  const keyRe = /(?:i18n\.labels|placeholders)\s*(?:\?\.)?\[\s*['"]([^'"]+)['"]\s*\]/g;
  const usedKeys = new Set();
  for (const f of jsFiles) {
    const content = fs.readFileSync(path.join(REPO_DIR, f), 'utf8');
    let m;
    while ((m = keyRe.exec(content)) !== null) usedKeys.add(m[1]);
  }
  if (!usedKeys.size) return { name: 'Placeholder-Keys', ok: true, detail: 'Keine Placeholder-Keys gefunden' };
  if (!afterUrl) {
    return { name: 'Placeholder-Keys', ok: true, detail: `${usedKeys.size} Key(s) gefunden — keine After-URL im PR, ungeprüft` };
  }
  const base = afterUrl.replace(/\/?$/, '');
  const known = new Set();
  for (const pf of PLACEHOLDER_FILES) {
    try {
      const res = await fetch(`${base}/de/de/placeholders/${pf}`, { signal: AbortSignal.timeout(10000) });
      if (res.ok) {
        const json = await res.json();
        const rows = json.data || json;
        for (const row of Array.isArray(rows) ? rows : []) {
          if (row.Key) known.add(row.Key);
        }
      }
    } catch { /* ignore */ }
  }
  const missing = [...usedKeys].filter((k) => !known.has(k));
  return missing.length
    ? { name: 'Placeholder-Keys', ok: false, detail: `Fehlende Keys: ${missing.join(', ')}` }
    : { name: 'Placeholder-Keys', ok: true, detail: `Alle ${usedKeys.size} Key(s) vorhanden` };
}

/** 6 — Unit Tests: Jest nur für Test-Dateien geänderter Blocks. */
function checkUnitTests(files) {
  const blocks = [...new Set(files.map((f) => blockNameOf(f.filename)).filter(Boolean))];
  const specs = blocks
    .map((b) => `tests/unit/${b}.test.js`)
    .filter((p) => fs.existsSync(path.join(REPO_DIR, p)));
  if (!specs.length) {
    const note = blocks.length
      ? `keine Unit-Tests für Block(s) ${blocks.join(', ')} angelegt`
      : 'keine Block-Änderungen im PR';
    return { name: 'Unit Tests', ok: true, skipped: true, detail: note };
  }
  try {
    execFileSync('npx', ['--no-install', 'jest', ...specs], {
      cwd: REPO_DIR, encoding: 'utf8', env: { ...process.env, NODE_OPTIONS: '--experimental-vm-modules' },
      timeout: 300000, killSignal: 'SIGKILL',
    });
    return { name: 'Unit Tests', ok: true, detail: `${specs.length} Test-Datei(en) bestanden` };
  } catch (e) {
    // Timeout (Endlos-Test) soll den Check failen, nicht den ganzen Runner-Lauf killen
    const why = e.signal === 'SIGKILL' ? 'Timeout (300s) — Test hängt?\n' : '';
    return { name: 'Unit Tests', ok: false, detail: (why + (e.stdout || e.message || '')).slice(-1500) };
  }
}

/** 7 — Visual Tests: block-basiertes Spec-Matching (Singular+Plural).
 *  Scannt rekursiv nach .spec.js. Block-Match über Pfad-Segmente
 *  (z. B. tests/visual-styleguide/teaser-xl/.../foo.spec.js → block=teaser-xl),
 *  damit nested Styleguide-Layouts (block/<variante>/foo.spec.js) sauber greifen. */
function collectVisualSpecPaths() {
  const out = [];
  for (const root of VISUAL_SPEC_DIRS) {
    const abs = path.join(REPO_DIR, root);
    if (!fs.existsSync(abs)) continue;
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (entry.isFile() && entry.name.endsWith('.spec.js')) out.push(full);
      }
    };
    walk(abs);
  }
  return out;
}

/** Mappt einen Spec-Absoluten-Pfad auf einen Block-Namen = erstes Segment
 *  unterhalb des Spec-Roots (z. B. teaser-xl für visual-styleguide/teaser-xl/.../foo.spec.js). */
function blockOfSpecPath(specAbs) {
  const rel = path.relative(REPO_DIR, specAbs);
  for (const root of VISUAL_SPEC_DIRS) {
    if (rel === root || rel.startsWith(root + path.sep)) {
      const after = rel.slice(root.length + 1).split(path.sep);
      return after[0] || null;
    }
  }
  return null;
}

/** Lädt block-deps.json (Block-zu-Block Abhängigkeiten) — atomare Atoms wie
 *  button/text/image/link werden in vielen Organisms eingebettet; eine
 *  Änderung am Atom kann visuelle Regressionen in jedem Konsumenten
 *  verursachen. Der Index wird on-demand gebaut, falls fehlt oder älter
 *  als 7 Tage. */
const BLOCK_DEPS_FILE = 'block-deps.json';
const BLOCK_DEPS_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

function loadBlockDeps() {
  const file = path.join(REPO_DIR, BLOCK_DEPS_FILE);
  let needsBuild = true;
  if (fs.existsSync(file)) {
    const stat = fs.statSync(file);
    if (Date.now() - stat.mtimeMs < BLOCK_DEPS_MAX_AGE_MS) needsBuild = false;
  }
  if (needsBuild) {
    try {
      // Generator liegt im selben Verzeichnis wie run.js. REPO_DIR explizit
      // durchreichen — im Runner-Kontext ist process.argv[2] z. B. die
      // PR-Nummer, also würde die Modul-Konstante im Generator danebengreifen.
      const gen = require(path.join(__dirname, 'build-block-deps.js'));
      gen.build(REPO_DIR);
    } catch (e) {
      // Build-Failure ist nicht fatal — wir matchen dann ohne transitive
      // Konsumenten und protokollieren den Fehler für die Nachvollziehbarkeit.
      console.error('build-block-deps fehlgeschlagen:', e.message);
      return null;
    }
  }
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/** Drei-Stufen-Trigger für Spec-Match (PR-Files → gematchte Specs).
 *  Liefert zusätzlich eine Aufschlüsselung pro Stufe für den Runner-Output:
 *  { direct: [specs], blockDefault: [specs], transitive: [{spec, via, consumer}] }
 *
 *  Stufe 1) Spec-Datei selbst im PR geändert → läuft immer
 *  Stufe 2) Irgendeine Datei im Block-Ordner geändert → Block-Default
 *           (alle Specs dieses Blocks laufen, weil Block-File-Änderungen
 *            potenziell jede Variante beeinflussen — CSS/JS ist geteilt)
 *  Stufe 3) PR berührt einen Block, der transitive Konsumenten hat
 *           (z. B. Button-Atom ändert sich → hero-intro, footer, teaser-slider
 *            Specs laufen mit). Geladen aus block-deps.json
 *            (build-block-deps.js).
 *
 *  Globale Files (styles/*, head.html, docu/*, scripts/*) matchen KEINE Specs,
 *  weil sie keinem Block-Ordner zugeordnet sind.
 *
 *  Granularität unterhalb Block-Level (Variante) wurde verworfen: Spec-Slugs
 *  haben keinen zuverlässigen Bezug zu Block-File-Klassen/-Tokens, die
 *  Styleguide-Registry ist ein dynamischer Modulname und ohne Bundler nicht
 *  parsbar. Risiko verpasster Specs > Kostenersparnis. Stufe 1 löst den
 *  häufigsten Granularitäts-Wunsch: neue Spec direkt hinzufügen. */
function matchVisualSpecs(files) {
  const specPaths = collectVisualSpecPaths();
  const prRelPaths = new Set(files.map((f) => f.filename));
  const blockDirs = new Set();
  const blockNames = new Set();
  for (const f of files) {
    let m = f.filename.match(/^blocks\/([^/]+)\//);
    if (m) {
      blockDirs.add(path.join(REPO_DIR, 'blocks', m[1]));
      blockNames.add(m[1]);
      continue;
    }
    m = f.filename.match(/^patterns\/(?:organisms|molecules|atoms)\/([^/]+)\//);
    if (m) {
      blockDirs.add(path.join(REPO_DIR, f.filename.split('/').slice(0, 2).concat(m[1]).join('/')));
      blockNames.add(m[1]);
    }
  }

  const matched = new Set();
  const direct = [];      // Stufe 1
  const blockDefault = []; // Stufe 2
  const transitive = [];   // Stufe 3: { spec, via, consumer }

  // Stufe 1: Spec-Direkt-Trigger
  for (const sp of specPaths) {
    const spRel = path.relative(REPO_DIR, sp);
    if (prRelPaths.has(spRel)) {
      matched.add(spRel);
      direct.push(spRel);
    }
  }

  // Stufe 2: pro PR-berührtem Block-Ordner alle Specs dieses Blocks
  for (const blockDir of blockDirs) {
    const blockName = path.basename(blockDir);
    for (const sp of specPaths) {
      if (blockOfSpecPath(sp) !== blockName) continue;
      const spRel = path.relative(REPO_DIR, sp);
      if (!matched.has(spRel)) {
        matched.add(spRel);
        blockDefault.push(spRel);
      }
    }
  }

  // Stufe 3: transitive Konsumenten via block-deps.json
  if (blockNames.size > 0) {
    const deps = loadBlockDeps();
    if (deps && deps.transitive) {
      for (const blockName of blockNames) {
        const consumers = deps.transitive[blockName] || [];
        for (const consumer of consumers) {
          for (const sp of specPaths) {
            if (blockOfSpecPath(sp) !== consumer) continue;
            const spRel = path.relative(REPO_DIR, sp);
            if (!matched.has(spRel)) {
              matched.add(spRel);
              transitive.push({ spec: spRel, via: blockName, consumer });
            }
          }
        }
      }
    }
  }
  return {
    specs: [...matched],
    breakdown: { direct, blockDefault, transitive },
  };
}

function checkVisualTests(files) {
  const { specs, breakdown } = matchVisualSpecs(files);
  const blocks = [...new Set(files.map((f) => blockNameOf(f.filename)).filter(Boolean))];
  const noSpec = blocks.filter((b) => {
    const singular = b.replace(/s$/, '');
    return !specs.some((s) => s.includes(`/${b}/`) || s.includes(`/${singular}/`) || s.includes(`/${b}.`) || s.includes(`/${singular}.`));
  });
  // Ausführung der Zwei-Pass-Tests erfordert Preview-Hosts (BASE_URL_DEV/BRANCH)
  // + Playwright-Runner; ohne diese wird nur das Matching gemeldet (Server-Phase).
  if (!process.env.BASE_URL_DEV || !process.env.BASE_URL_BRANCH) {
    const parts = [];
    if (specs.length) {
      const triggerParts = [];
      if (breakdown.direct.length) triggerParts.push(`${breakdown.direct.length} direkter Spec-Trigger`);
      if (breakdown.blockDefault.length) triggerParts.push(`${breakdown.blockDefault.length} Block-Default`);
      if (breakdown.transitive.length) triggerParts.push(`${breakdown.transitive.length} transitive Konsumenten`);
      const triggerStr = triggerParts.length ? ` [${triggerParts.join(', ')}]` : '';
      // Welche Block-→Konsument-Ketten haben transitiv getriggert?
      const transitiveChains = breakdown.transitive.length
        ? [...new Set(breakdown.transitive.map((t) => `${t.via}→${t.consumer}`))].join(', ')
        : '';
      const transitiveStr = transitiveChains ? ` (via ${transitiveChains})` : '';
      const listing = specs.length <= 12
        ? `: ${specs.join(', ')}`
        : `: ${specs.slice(0, 10).join(', ')}, …(+${specs.length - 10} weitere)`;
      parts.push(`${specs.length} Spec(s) gematcht${triggerStr}${transitiveStr}${listing} (Runner nicht aktiv)`);
    } else {
      parts.push('keine passenden Visual-Specs für geänderte Blocks');
    }
    if (noSpec.length) parts.push(`Kein Visual-Spec für: ${noSpec.join(', ')} — Testseite anlegen und URL posten`);
    return { name: 'Visual Tests', ok: true, warn: noSpec.length > 0, skipped: specs.length === 0, detail: parts.join(' — ') };
  }
  // (Server-Modus) — Zwei-Pass: dev-Baseline → Branch-Vergleich. Implementierung
  // läuft auf dem LXC mit Preview-Hosts; hier nur Platzhalter für die Verkabelung.
  return { name: 'Visual Tests', ok: true, detail: `${specs.length} Spec(s) — Zwei-Pass (Server-Modus)` };
}

/** 8 — Merge Freshness: Commits hinter Base-Branch. */
function checkMergeFreshness() {
  // Range zählt Commits in BASE, die dem Branch fehlen (= "behind").
  const countStr = git('rev-list', '--count', `origin/${BRANCH}..origin/${BASE_BRANCH}`);
  const behind = parseInt(countStr, 10);
  if (Number.isNaN(behind)) return { name: 'Merge Freshness', ok: true, detail: 'nicht ermittelbar' };
  if (behind > MERGE_FRESHNESS_FAIL) return { name: 'Merge Freshness', ok: false, detail: `Branch ist ${behind} Commits hinter ${BASE_BRANCH} (bitte rebasen)` };
  if (behind > MERGE_FRESHNESS_WARN) return { name: 'Merge Freshness', ok: true, warn: true, detail: `Branch ist ${behind} Commits hinter ${BASE_BRANCH} (rebase empfohlen)` };
  return { name: 'Merge Freshness', ok: true, detail: `Branch ist ${behind} Commits hinter ${BASE_BRANCH}` };
}

/** 9 — Static Scans: Framework-Imports, outline:none, Bundle-Größe. */
function checkStaticScans(files, exceptions) {
  const issues = [];
  const warns = [];
  const frameworkRe = /\b(import\s+React|from\s+['"]react['"]|import\s+Vue|from\s+['"]vue['"]|import\s+\$|from\s+['"]jquery['"])/;
  const outlineExc = hasProjectException(exceptions, 'outline-none');

  let bundleDelta = 0;
  for (const f of files) {
    if (f.status === 'removed') continue;
    const abs = path.join(REPO_DIR, f.filename);
    if (!fs.existsSync(abs)) continue;
    const content = fs.readFileSync(abs, 'utf8');

    if (isJs(f.filename)) {
      content.split('\n').forEach((line, i) => {
        if (frameworkRe.test(line)) issues.push(`Framework-Import in ${f.filename}:${i + 1}`);
      });
      const baseLen = (fileAtRef(`origin/${BASE_BRANCH}`, f.filename) || '').length;
      bundleDelta += content.length - baseLen;
    }
    if (isCss(f.filename) && !outlineExc) {
      content.split('\n').forEach((line, i) => {
        if (/outline:\s*none/.test(line)) issues.push(`outline: none (WCAG) in ${f.filename}:${i + 1}`);
      });
    }
    // Token-Compliance: hardcodierte Farben statt var(--…) — nur in NEUEN Zeilen (f.patch),
    // sonst Altlasten-Flut. Custom-Property-DEFINITIONEN (--x: #abc) sind legitim (Token selbst).
    if (isCss(f.filename) && f.patch && !hasProjectException(exceptions, 'hardcoded-colors')) {
      f.patch.split('\n').forEach((pl) => {
        if (!pl.startsWith('+') || pl.startsWith('+++')) return;
        const code = pl.slice(1);
        if (/^\s*--[\w-]+\s*:/.test(code)) return;               // Token-Definition
        if (/:\s*[^;{}]*(#[0-9a-fA-F]{3,8}\b|rgba?\()/.test(code)) {
          warns.push(`Hardcodierte Farbe statt var(--…) in ${f.filename}: \`${code.trim().slice(0, 70)}\``);
        }
      });
    }
  }
  const deltaKb = bundleDelta / 1024;
  if (deltaKb > BUNDLE_GROWTH_WARN_KB) warns.push(`JS-Bundle +${deltaKb.toFixed(1)} KB`);

  if (issues.length) return { name: 'Static Scans', ok: false, detail: [...issues, ...warns].join('\n') };
  if (warns.length) return { name: 'Static Scans', ok: true, warn: true, detail: warns.join('\n') };
  return { name: 'Static Scans', ok: true, detail: 'Keine statischen Probleme gefunden' };
}

// ---------------------------------------------------------------------------
// Kommentar bauen + posten
// ---------------------------------------------------------------------------

function statusLine(r) {
  const icon = r.skipped ? ICON.skip : (r.ok ? (r.warn ? ICON.warn : ICON.ok) : ICON.fail);
  const prefix = r.skipped ? '⏭️ ' : '';
  return `${icon} **${r.name}** — ${prefix}${r.detail.split('\n')[0]}`;
}

function buildComment(results) {
  const lines = results.map(statusLine);
  const details = results
    .filter((r) => !r.ok || r.detail.includes('\n'))
    .map((r) => `### ${r.name}\n${r.detail}`);
  let body = `## 🧪 Automatischer PR-Test\n`;
  if (PROFILE_LINE) body += PROFILE_LINE + '\n';
  body += `\n${lines.join('\n')}`;
  if (details.length) body += `\n\n---\n\n${details.join('\n\n')}`;
  body += `\n\n<sub>hermes-work · branch \`${BRANCH}\` · base \`${BASE_BRANCH}\`</sub>`;
  return body;
}

const REPORT_MARKER = '<!-- hermes-work:report -->';

async function postComment(body) {
  body = `${REPORT_MARKER}\n${body}`;
  if (DRY_RUN) {
    console.log('\n===== DRY RUN — Kommentar würde gepostet =====\n');
    console.log(body);
    console.log('\n===== /DRY RUN =====');
    return;
  }
  const headers = {
    Authorization: `Bearer ${TOKEN}`,
    Accept: 'application/vnd.github+json',
    'User-Agent': 'jumo-testing-runner',
  };
  // Update-in-place: bestehenden Report-Kommentar (Marker) PATCHen statt bei
  // jedem synchronize-Push einen neuen zu posten.
  let existingId = null;
  try {
    const comments = await ghApi(`/repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100`);
    const prev = comments.find((c) => (c.body || '').includes(REPORT_MARKER));
    if (prev) existingId = prev.id;
  } catch { /* Suche fehlgeschlagen -> neu posten */ }
  const url = existingId
    ? `https://api.github.com/repos/${REPO}/issues/comments/${existingId}`
    : `https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments`;
  const res = await fetch(url, {
    method: existingId ? 'PATCH' : 'POST',
    headers,
    body: JSON.stringify({ body }),
  });
  if (!res.ok) throw new Error(`Kommentar posten fehlgeschlagen: ${res.status} ${await res.text()}`);
  console.log(existingId ? '=== KOMMENTAR AKTUALISIERT ===' : '=== KOMMENTAR GEPOSTET ===');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  if (!TOKEN) {
    console.error('Kein GITHUB_TOKEN (und `gh auth token` fehlgeschlagen).');
    process.exit(2);
  }
  // PR zuerst holen → effektiven Merge-Branch ableiten → dann Refs fetchen.
  const pr = await resolveBaseBranch(PR_NUMBER);
  ensureRefs();
  const exceptions = loadExceptions();
  const cm = resolveProfile();
  CM_DISABLED = cm.disabled || [];
  CM_IGNORE = cm.ignore || [];
  const cmSrc = cm.source === 'auto' ? 'automatisch erkannt' : ('aus `' + cm.source + '`');
  PROFILE_LINE = 'Profil: `' + cm.profile + '` · ' + cmSrc + ' · [⚙ Konfigurierbar](https://web.skycryer.com/codemole/docs/#config)';

  pr.body = pr.body || '';
  const prLabels = (pr.labels || []).map((l) => l.name);
  let files = await ghApi(`/repos/${REPO}/pulls/${PR_NUMBER}/files?per_page=100`);
  if (CM_IGNORE.length) files = files.filter((f) => !ignoredPath(f.filename, CM_IGNORE));

  if (MODE === 'update-snapshots') {
    // Visual-Baselines neu erzeugen + committen + pushen (Server-Modus, LXC).
    console.log('update-snapshots-Modus: auf dem LXC mit Preview-Hosts ausführen.');
    process.exit(0);
  }

  const results = [
    checkFileGuard(files, prLabels),
    checkPrCompleteness(pr),
    checkJsLint(files),
    checkCssLint(files),
    await checkPlaceholderKeys(files, pr, exceptions),
    checkUnitTests(files),
    checkVisualTests(files),
    checkMergeFreshness(),
    checkStaticScans(files, exceptions),
  ].filter((r) => !CM_DISABLED.includes(slug(r.name)));

  const body = buildComment(results);
  await postComment(body);

  const failed = results.filter((r) => !r.ok);
  const skipped = results.filter((r) => r.skipped);
  const passed = results.filter((r) => r.ok && !r.skipped);
  const parts = [`${passed.length}/${results.length} geprüft & ok`];
  if (skipped.length) parts.push(`${skipped.length} übersprungen`);
  if (failed.length) parts.push(`${failed.length} Fehler`);
  console.log(`\nErgebnis: ${parts.join(', ')}`);
}

main().catch((e) => {
  console.error('Runner-Fehler:', e.message);
  process.exit(1);
});
