#!/usr/bin/env node
/**
 * lighthouse-Lauf für CodeMole — SCHWER (Minuten), läuft deshalb NICHT bei jedem Push,
 * sondern nur on-demand: Label `lighthouse` an den PR hängen (Handler-Trigger).
 *
 * Zwei-Pass: Scores (Performance/Accessibility/Best-Practices/SEO) auf BASE- und
 * BRANCH-Preview je Seite, Vergleich als PR-Kommentar (Upsert). Nutzt dieselbe
 * .codemole.yml-Config wie page-audit (page-audit.base_url/pages; optional
 * lighthouse.pages als Override, Cap 2 Seiten).
 *
 * Usage: node lighthouse.js <owner/repo> <pr> <branch> <base>
 * Env: REPO_DIR, GITHUB_TOKEN, DRY_RUN=1, PAGE_AUDIT_CONFIG (Test-Override)
 */
'use strict';
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const [, , REPO, PR, BRANCH, BASE] = process.argv;
if (!REPO || !PR || !BRANCH || !BASE) {
  console.error('usage: lighthouse.js <owner/repo> <pr> <branch> <base>');
  process.exit(2);
}
const TOKEN = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
const DRY = process.env.DRY_RUN === '1';
const MARKER = '<!-- codemole:lighthouse -->';
const CATS = ['performance', 'accessibility', 'best-practices', 'seo'];

// Playwright-Chromium als Chrome für Lighthouse
function chromePath() {
  const roots = fs.readdirSync('/root/.cache/ms-playwright').filter((d) => /^chromium-\d+$/.test(d));
  for (const r of roots) {
    const p = `/root/.cache/ms-playwright/${r}/chrome-linux64/chrome`;
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function loadConfig() {
  if (process.env.PAGE_AUDIT_CONFIG) {
    try { return JSON.parse(process.env.PAGE_AUDIT_CONFIG); } catch { return null; }
  }
  try {
    const out = execFileSync('python3',
      [path.join(__dirname, '..', 'resolve-profile.py'), process.env.REPO_DIR || '.', REPO],
      { encoding: 'utf8' });
    const opts = JSON.parse(out).options || {};
    const pa = opts['page-audit'] || {};
    const lh = opts.lighthouse || {};
    return { base_url: lh.base_url || pa.base_url, pages: lh.pages || pa.pages };
  } catch { return null; }
}

function runLighthouse(url, chrome) {
  const out = `/tmp/lh-${process.pid}-${Math.abs(url.split('').reduce((a, c) => a * 31 + c.charCodeAt(0) | 0, 7))}.json`;
  try {
    execFileSync('npx', ['lighthouse', url,
      '--output=json', `--output-path=${out}`, '--quiet',
      `--only-categories=${CATS.join(',')}`,
      '--chrome-flags=--headless --no-sandbox --disable-dev-shm-usage'],
      { cwd: __dirname, encoding: 'utf8', timeout: 180000, env: { ...process.env, CHROME_PATH: chrome } });
    const r = JSON.parse(fs.readFileSync(out, 'utf8'));
    const scores = {};
    for (const c of CATS) scores[c] = Math.round(((r.categories[c] || {}).score || 0) * 100);
    scores._lcp = Math.round((r.audits['largest-contentful-paint'] || {}).numericValue || 0);
    scores._cls = Number(((r.audits['cumulative-layout-shift'] || {}).numericValue || 0).toFixed(3));
    return scores;
  } catch (e) {
    return { error: (e.message || '').slice(0, 120) };
  } finally {
    try { fs.unlinkSync(out); } catch {}
  }
}

async function upsertComment(body) {
  const H = { Authorization: `Bearer ${TOKEN}`, Accept: 'application/vnd.github+json', 'User-Agent': 'codemole-lighthouse', 'Content-Type': 'application/json' };
  const list = await fetch(`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100`, { headers: H });
  const comments = list.ok ? await list.json() : [];
  const mine = comments.find((c) => (c.body || '').includes(MARKER));
  const payload = JSON.stringify({ body });
  if (mine) await fetch(`https://api.github.com/repos/${REPO}/issues/comments/${mine.id}`, { method: 'PATCH', headers: H, body: payload });
  else await fetch(`https://api.github.com/repos/${REPO}/issues/${PR}/comments`, { method: 'POST', headers: H, body: payload });
}

(async () => {
  const cfg = loadConfig();
  if (!cfg || !cfg.base_url || !Array.isArray(cfg.pages) || !cfg.pages.length) {
    console.log('LIGHTHOUSE: nicht konfiguriert (page-audit/lighthouse in .codemole.yml) — übersprungen');
    return;
  }
  const chrome = chromePath();
  if (!chrome) { console.log('LIGHTHOUSE: kein Chromium gefunden'); return; }
  const pages = cfg.pages.slice(0, 2); // schwer → hartes Cap

  const dif = (b, n) => { const d = n - b; return d === 0 ? `${n}` : `${n} (${d > 0 ? '+' : ''}${d})`; };
  const rows = [];
  let worst = 0;
  for (const p of pages) {
    const u = (br) => cfg.base_url.replace('{branch}', String(br).toLowerCase()) + p;
    const b = runLighthouse(u(BASE), chrome);
    const n = runLighthouse(u(BRANCH), chrome);
    if (b.error || n.error) {
      rows.push(`| \`${p}\` | ${n.error ? '❌ ' + n.error : '—'} | | | | |`);
      continue;
    }
    for (const c of CATS) worst = Math.min(worst, n[c] - b[c]);
    rows.push(`| \`${p}\` | ${dif(b.performance, n.performance)} | ${dif(b.accessibility, n.accessibility)} | ${dif(b['best-practices'], n['best-practices'])} | ${dif(b.seo, n.seo)} | LCP ${n._lcp} ms · CLS ${n._cls} |`);
  }

  const verdict = worst < -2 ? `⚠️ Verschlechterung bis zu ${worst} Punkte gegenüber \`${BASE}\`` : `✅ keine relevante Verschlechterung gegenüber \`${BASE}\``;
  const body = `${MARKER}\n## ⚡ Lighthouse\n${verdict}\n\n| Seite | Perf | A11y | Best-P. | SEO | Metriken (Branch) |\n|---|---|---|---|---|---|\n${rows.join('\n')}\n\n<sub>CodeMole lighthouse · on-demand via Label \`lighthouse\` · Werte = Branch (Δ zu Base)</sub>`;
  console.log(`LIGHTHOUSE: fertig (${pages.length} Seite(n), worst Δ ${worst})`);
  if (DRY) { console.log('\n' + body); return; }
  if (!TOKEN) { console.log('LIGHTHOUSE: kein Token — nicht gepostet'); return; }
  await upsertComment(body);
  console.log('LIGHTHOUSE: Kommentar aktualisiert/gepostet');
})().catch((e) => { console.error('LIGHTHOUSE-Fehler:', e.message); process.exit(0); });
