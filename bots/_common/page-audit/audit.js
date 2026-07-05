#!/usr/bin/env node
/**
 * page-audit — schneller Seiten-Audit für CodeMole (a11y + Semantik + Timing).
 *
 * Zwei-Pass: jede konfigurierte Seite wird auf der BASE-Preview und der BRANCH-Preview
 * gerendert und mit axe-core (WCAG 2.1 A/AA + Best Practice, deckt Semantik wie
 * heading-order/landmarks/alt mit ab) geprüft. Gemeldet werden NUR Findings, die auf
 * dem Branch NEU sind (Lehre aus dem yamllint-Altlasten-Problem). Timing (DCL/Load/
 * Transfer) wird informativ mitgezeigt, ohne zu warnen (CDN-Rauschen).
 *
 * Aktivierung pro Repo via .codemole.yml:
 *   page-audit:
 *     base_url: "https://{branch}--jumo-website-dev--jumo-gmbh-co-kg.aem.page"
 *     pages: ["/de/de/", "/de/de/products/..."]
 * Ohne Config: no-op (exit 0). {branch} wird lowercased ersetzt (EDS-Konvention).
 *
 * Usage: node audit.js <owner/repo> <pr> <branch> <base>
 * Env: REPO_DIR (für resolve-profile.py), GITHUB_TOKEN (Kommentar), DRY_RUN=1 (nur stdout),
 *      PAGE_AUDIT_CONFIG (JSON-Override der Config, für Tests).
 */
'use strict';
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { chromium } = require('playwright');
const { AxeBuilder } = require('@axe-core/playwright');

const [, , REPO, PR, BRANCH, BASE] = process.argv;
if (!REPO || !PR || !BRANCH || !BASE) {
  console.error('usage: audit.js <owner/repo> <pr> <branch> <base>');
  process.exit(2);
}
const TOKEN = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
const DRY = process.env.DRY_RUN === '1';
const MAX_PAGES = 5;
const MARKER = '<!-- codemole:page-audit -->';
function detectLang() {
  try {
    return execFileSync('bash', [path.join(__dirname, '..', 'detect-lang.sh'), REPO, String(PR)], { encoding: 'utf8' }).trim() === 'en' ? 'en' : 'de';
  } catch { return 'de'; }
}
const L = detectLang();

function loadConfig() {
  if (process.env.PAGE_AUDIT_CONFIG) {
    try { return JSON.parse(process.env.PAGE_AUDIT_CONFIG); } catch { return null; }
  }
  try {
    const out = execFileSync('python3',
      [path.join(__dirname, '..', 'resolve-profile.py'), process.env.REPO_DIR || '.', REPO],
      { encoding: 'utf8' });
    return (JSON.parse(out).options || {})['page-audit'] || null;
  } catch { return null; }
}

function pageUrl(tmpl, branch, p) {
  return tmpl.replace('{branch}', String(branch).toLowerCase()) + p;
}

async function auditPage(browser, url) {
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 });
    if (!resp || resp.status() >= 400) {
      return { error: `HTTP ${resp ? resp.status() : 'timeout'}` };
    }
    const axe = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'best-practice'])
      .analyze();
    const timing = await page.evaluate(() => {
      const n = performance.getEntriesByType('navigation')[0] || {};
      return {
        dcl: Math.round(n.domContentLoadedEventEnd || 0),
        load: Math.round(n.loadEventEnd || 0),
        kb: Math.round((n.transferSize || 0) / 1024),
      };
    });
    // Violations als vergleichbare Keys: regelId + Ziel-Selektor
    const violations = [];
    for (const v of axe.violations) {
      for (const node of v.nodes) {
        violations.push({
          key: `${v.id}|${(node.target || []).join(' ')}`,
          id: v.id, impact: v.impact || 'minor',
          target: (node.target || []).join(' '),
          help: v.help,
        });
      }
    }
    return { violations, timing };
  } catch (e) {
    return { error: e.message.slice(0, 140) };
  } finally {
    await context.close();
  }
}

async function upsertComment(body) {
  const H = { Authorization: `Bearer ${TOKEN}`, Accept: 'application/vnd.github+json', 'User-Agent': 'codemole-page-audit', 'Content-Type': 'application/json' };
  const list = await fetch(`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100`, { headers: H });
  const comments = list.ok ? await list.json() : [];
  const mine = comments.find((c) => (c.body || '').includes(MARKER));
  const payload = JSON.stringify({ body });
  if (mine) {
    await fetch(`https://api.github.com/repos/${REPO}/issues/comments/${mine.id}`, { method: 'PATCH', headers: H, body: payload });
  } else {
    await fetch(`https://api.github.com/repos/${REPO}/issues/${PR}/comments`, { method: 'POST', headers: H, body: payload });
  }
}

(async () => {
  const cfg = loadConfig();
  if (!cfg || !cfg.base_url || !Array.isArray(cfg.pages) || !cfg.pages.length) {
    console.log('PAGE-AUDIT: nicht konfiguriert (page-audit.base_url/pages in .codemole.yml) — übersprungen');
    return;
  }
  const pages = cfg.pages.slice(0, cfg.max_pages || MAX_PAGES);
  if (cfg.pages.length > pages.length) console.log(`PAGE-AUDIT: ${cfg.pages.length - pages.length} Seite(n) über dem Limit — nicht geprüft`);

  const browser = await chromium.launch();
  const results = [];
  try {
    for (const p of pages) {
      const [baseRes, branchRes] = [
        await auditPage(browser, pageUrl(cfg.base_url, BASE, p)),
        await auditPage(browser, pageUrl(cfg.base_url, BRANCH, p)),
      ];
      results.push({ page: p, baseRes, branchRes });
    }
  } finally {
    await browser.close();
  }

  const sections = [];
  let totalNew = 0;
  for (const r of results) {
    if (r.branchRes.error) {
      totalNew += 1;
      sections.push(L === 'en' ? `**${r.page}** — ❌ branch preview fails to load (${r.branchRes.error})` : `**${r.page}** — ❌ Branch-Preview lädt nicht (${r.branchRes.error})`);
      continue;
    }
    const baseKeys = new Set(r.baseRes.error ? [] : r.baseRes.violations.map((v) => v.key));
    const fresh = r.branchRes.violations.filter((v) => !baseKeys.has(v.key));
    // pro Regel gruppieren
    const byRule = new Map();
    for (const v of fresh) {
      if (!byRule.has(v.id)) byRule.set(v.id, { ...v, count: 0, targets: [] });
      const g = byRule.get(v.id); g.count += 1;
      if (g.targets.length < 3) g.targets.push(v.target);
    }
    totalNew += fresh.length;
    if (byRule.size) {
      const noBase = r.baseRes.error ? (L === 'en' ? ' *(no base comparison possible — showing all findings)*' : ' *(kein Base-Vergleich möglich — alle Findings gezeigt)*') : '';
      const t = r.branchRes.timing;
      const lines = [...byRule.values()].map((g) =>
        `- ${g.impact === 'critical' || g.impact === 'serious' ? '⚠️' : '•'} \`${g.id}\` (${g.impact}): ${g.count} Element(e) — ${g.help}. z. B. \`${g.targets[0]}\``);
      sections.push(`**${r.page}**${noBase} · DCL ${t.dcl} ms · Load ${t.load} ms · ${t.kb} KB\n${lines.join('\n')}`);
    }
  }

  console.log(`PAGE-AUDIT: ${totalNew} neue Finding(s)`);
  if (!totalNew) return;

  const head = L === 'en'
    ? `${totalNew} new finding(s) compared to \`${BASE}\` (axe-core · WCAG 2.1 A/AA + best practice · regressions only)`
    : `${totalNew} neue Finding(s) gegenüber \`${BASE}\` (axe-core · WCAG 2.1 A/AA + Best Practice · nur Verschlechterungen)`;
  const foot = L === 'en' ? 'CodeMole page-audit · two-pass base↔branch · timing informational' : 'CodeMole page-audit · Zwei-Pass base↔branch · Timing informativ';
  const body = `${MARKER}\n## 🔎 Page-Audit\n${head}:\n\n${sections.join('\n\n')}\n\n<sub>${foot}</sub>`;
  if (DRY) { console.log('\n' + body); return; }
  if (!TOKEN) { console.log('PAGE-AUDIT: kein Token — nicht gepostet'); return; }
  await upsertComment(body);
  console.log('PAGE-AUDIT: Kommentar aktualisiert/gepostet');
})().catch((e) => { console.error('PAGE-AUDIT-Fehler:', e.message); process.exit(0); });
