#!/usr/bin/env node
/**
 * Hermes-Work Discord-Listener
 *
 * Listens on configured Discord channels for TEST_REQUEST / PR_READY /
 * PR_COMMENT messages, parses the repo + PR number from the footer, and
 * invokes `bots/<project>/test-pr.sh` to run the project-specific tests.
 * Posts the result back as a PR comment via gh api.
 *
 * Architecture:
 *   Discord Channel  →  bot listener  →  bots/<project>/test-pr.sh  →  GitHub PR comment
 *                                              ↓
 *                                         (project-specific checks)
 *
 * Channel → Repo mapping in discord-listener-config.json.
 *
 * Trigger messages (footer text, case-insensitive):
 *   TEST_REQUEST branch=<x> pr=<n>      → run tests, post report
 *   JUMO_TEST_REQUEST branch=<x> pr=<n> → run tests, post report (JUMO only)
 *   retest                              → re-run last test for this PR
 *   snapshots update                    → call test-pr.sh with mode=update-snapshots
 *
 * Run via systemd: `systemctl start hermes-discord-listener`
 */

'use strict';

const { Client, GatewayIntentBits, Events, EmbedBuilder } = require('discord.js');
const { spawn, execSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// --- Config ----------------------------------------------------------------

const CONFIG_PATH = process.env.HERMES_LISTENER_CONFIG
  || path.join(__dirname, 'discord-listener-config.json');
const TOKEN_PATH = process.env.HERMES_DISCORD_TOKEN
  || '/root/.config/discord-bot-token.txt';
const LOG_PATH = process.env.HERMES_LISTENER_LOG
  || '/var/log/hermes-discord-listener.log';
const BOTS_DIR = process.env.HERMES_BOTS_DIR
  || '/opt/hermes-work-commons/bots';
const GITHUB_TOKEN_PATH = process.env.HERMES_GH_TOKEN
  || '/root/.config/gh-token-raw.txt';

let config;
try {
  config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch (e) {
  log(`FATAL: cannot read config ${CONFIG_PATH}: ${e.message}`);
  process.exit(1);
}

// channels: Map<channelId, {repo, name, project}>
const channels = new Map();
for (const ch of config.channels) {
  channels.set(ch.id, ch);
}

// --- Logging ---------------------------------------------------------------

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  process.stdout.write(line);
  try { fs.appendFileSync(LOG_PATH, line); } catch {}
}

// --- Token Loading ---------------------------------------------------------

let discordToken, githubToken;

function loadDiscordToken() {
  try {
    discordToken = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
    if (!discordToken) throw new Error('empty file');
    log(`discord token loaded (${discordToken.length} chars)`);
  } catch (e) {
    log(`FATAL: cannot read discord token from ${TOKEN_PATH}: ${e.message}`);
    process.exit(1);
  }
}

function loadGithubToken() {
  try {
    const stat = fs.statSync(GITHUB_TOKEN_PATH);
    // Refuse to proceed if token file is world-readable — fail-fast on
    // accidental chmod 644 (or worse). Service runs as root.
    if ((stat.mode & 0o077) !== 0) {
      throw new Error(`token file ${GITHUB_TOKEN_PATH} has permissive mode ${(stat.mode & 0o777).toString(8)} (need 600)`);
    }
    githubToken = fs.readFileSync(GITHUB_TOKEN_PATH, 'utf8').trim();
    if (!githubToken) throw new Error('empty file');
    log(`github token loaded (${githubToken.length} chars)`);
  } catch (e) {
    log(`FATAL: cannot read github token from ${GITHUB_TOKEN_PATH}: ${e.message}`);
    process.exit(1);
  }
}

// --- Message Parsing -------------------------------------------------------

// Footer format: "TEST_REQUEST branch=wcms-1234 pr=440 repo=JUMO-GmbH-Co-KG/JUMO-Website-CMS"
// Also accepts PR_READY and PR_COMMENT as synonymous triggers (advertised in
// trigger_pattern docs and SETUP.md), and JUMO_TEST_REQUEST as a project-scoped
// variant.
const TRIGGER_PATTERN = /^(?:JUMO_)?(?:TEST_REQUEST|PR_READY|PR_COMMENT)\s+branch=(\S+)\s+pr=(\d+)(?:\s+repo=(\S+))?/i;

function parseTestRequest(content) {
  const m = content.match(TRIGGER_PATTERN);
  if (!m) return null;
  // Normalise prefix to one of: TEST_REQUEST | JUMO_TEST_REQUEST.
  // PR_READY / PR_COMMENT are accepted as trigger names but behave
  // identically to TEST_REQUEST at the dispatcher level.
  const fullMatch = m[0].match(/^(JUMO_)?(?:TEST_REQUEST|PR_READY|PR_COMMENT)/i);
  const prefix = (fullMatch && fullMatch[1] ? 'JUMO_TEST_REQUEST' : 'TEST_REQUEST');
  return {
    prefix,
    branch: m[1],
    pr: m[2],
    repo: m[3] || null,  // null = use channel default
  };
}

// --- Input Validation ------------------------------------------------------

// Whitelist of characters safe for a git branch name. Used to reject shell-meta
// and path-traversal attempts in Discord messages before they reach a shell.
const SAFE_BRANCH = /^[A-Za-z0-9._\/-]+$/;

function validateBranch(branch) {
  if (!branch || branch.length > 200) return false;
  if (branch.includes('..')) return false;       // path traversal
  if (branch.startsWith('-')) return false;      // looks like a CLI flag
  if (branch.startsWith('/') || branch.includes('\0')) return false;
  return SAFE_BRANCH.test(branch);
}

function validatePr(pr) {
  const n = Number(pr);
  return Number.isInteger(n) && n > 0 && n < 10_000_000;
}

// --- Bot Identification ----------------------------------------------------

// Resolve the project directory (under BOTS_DIR) for a repo. The mapping
// MUST come from the channel config — repo names do not always match
// project directory names (e.g. JUMO-GmbH-Co-KG/JUMO-Website-CMS → "jumo").
// `channelCfg` is the only authoritative source; this function is a
// last-resort fallback used only when channelCfg.project is missing.
function projectForRepo(repoFullName) {
  const parts = repoFullName.split('/');
  if (parts.length !== 2) return null;
  const [owner, name] = parts;
  // Reject anything that could escape BOTS_DIR via path traversal.
  if (!/^[A-Za-z0-9._-]+$/.test(owner) || !/^[A-Za-z0-9._-]+$/.test(name)) {
    return null;
  }
  if (name === 'JUMO-Website-CMS') return 'jumo';
  return name;  // for SkyTechNerds/ha-soft-presence etc.
}

function resolveProject(channelCfg, repoFullName) {
  // Prefer the configured project name (authoritative). Fall back to
  // repo-derived name only when the config genuinely lacks a project field.
  if (channelCfg && typeof channelCfg.project === 'string'
      && /^[A-Za-z0-9._-]+$/.test(channelCfg.project)) {
    return channelCfg.project;
  }
  return projectForRepo(repoFullName);
}

// --- Test Invocation -------------------------------------------------------

function runTest(repoFullName, pr, branch, project, mode = 'collect') {
  // Defensive: project was already validated by resolveProject, but assert
  // again here in case runTest is called from a future code path that
  // forgets to validate.
  if (!project || !/^[A-Za-z0-9._-]+$/.test(project)) {
    throw new Error(`refusing to run: invalid project name "${project}"`);
  }
  const script = path.join(BOTS_DIR, project, 'test-pr.sh');
  // Resolve and verify the script lives under BOTS_DIR (no symlink escape).
  const realBots = fs.realpathSync(BOTS_DIR);
  const realScript = fs.realpathSync(script);
  if (!realScript.startsWith(realBots + path.sep)) {
    throw new Error(`test script ${realScript} is outside BOTS_DIR ${realBots}`);
  }
  if (!fs.existsSync(realScript)) {
    throw new Error(`No test script at ${realScript}`);
  }
  log(`running ${realScript} ${pr} ${branch} ${mode}`);
  const env = { ...process.env, REPO: repoFullName, PATH: process.env.PATH };
  const result = spawn('bash', [realScript, String(pr), branch, 'main', mode], {
    env,
    cwd: BOTS_DIR,
    timeout: 600_000,  // 10 min
  });
  return new Promise((resolve, reject) => {
    let stdout = '', stderr = '';
    result.stdout.on('data', d => stdout += d);
    result.stderr.on('data', d => stderr += d);
    result.on('close', code => {
      log(`test exit ${code}: ${stdout.slice(-200)}`);
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`test exit ${code}: ${stderr.slice(-500)}`));
    });
  });
}

// --- GitHub PR Comment Posting ---------------------------------------------

/**
 * Post a comment to a GitHub PR. Resolves with {ok, status, body} so the
 * caller can react to GitHub-side failures instead of reporting success
 * to Discord when the PR comment never landed.
 */
async function postPRComment(repoFullName, pr, body) {
  if (!githubToken) {
    log('skipping PR comment: no github token');
    return { ok: false, status: 0, body: 'no github token' };
  }
  const url = `https://api.github.com/repos/${repoFullName}/issues/${pr}/comments`;
  const payload = JSON.stringify({ body });
  return new Promise((resolve) => {
    const proc = spawn('curl', [
      '-sS', '-w', '\n__HTTP_STATUS__:%{http_code}',
      '-X', 'POST', url,
      '-H', `Authorization: token ${githubToken}`,
      '-H', 'Content-Type: application/json',
      '-H', 'User-Agent: hermes-discord-listener',
      '-d', payload,
    ]);
    let out = '', err = '';
    proc.stdout.on('data', d => out += d);
    proc.stderr.on('data', d => err += d);
    proc.on('close', code => {
      const m = out.match(/__HTTP_STATUS__:(\d+)\s*$/);
      const status = m ? parseInt(m[1], 10) : 0;
      const bodyOnly = out.replace(/__HTTP_STATUS__:\d+\s*$/, '');
      if (code !== 0) {
        log(`PR comment curl exit ${code}: ${err.slice(0, 200)}`);
        return resolve({ ok: false, status, body: `curl exit ${code}: ${err.slice(0, 500)}` });
      }
      if (status < 200 || status >= 300) {
        log(`PR comment HTTP ${status}: ${bodyOnly.slice(0, 200)}`);
        return resolve({ ok: false, status, body: bodyOnly });
      }
      log(`PR comment OK (HTTP ${status})`);
      resolve({ ok: true, status, body: bodyOnly });
    });
  });
}

// --- Main Handler ----------------------------------------------------------

async function handleTestRequest(message, channelCfg, parsed) {
  // channelCfg is AUTHORITATIVE: ignore parsed.repo (could be attacker-
  // controlled via Discord message). Always use the repo bound to the channel.
  const repo = channelCfg && channelCfg.repo;
  const { pr, branch, prefix } = parsed;

  // Prefix must match what this channel declares. e.g. a TEST_REQUEST in the
  // JUMO channel (which expects JUMO_TEST_REQUEST) must be rejected so users
  // cannot accidentally fire the wrong project's runner.
  if (!channelCfg || !repo) {
    return message.reply('❌ Channel not configured for test runs.');
  }
  const expectedPrefix = channelCfg.trigger_prefix || 'TEST_REQUEST';
  if (prefix !== expectedPrefix) {
    return message.reply(`❌ Wrong trigger for this channel: expected ${expectedPrefix}, got ${prefix}.`);
  }

  // Validate inputs BEFORE passing them to a shell-spawning script.
  if (!validateBranch(branch)) {
    return message.reply(`❌ Invalid branch name: \`${branch.slice(0, 80)}\``);
  }
  if (!validatePr(pr)) {
    return message.reply(`❌ Invalid PR number: \`${pr}\``);
  }

  const project = resolveProject(channelCfg, repo);
  if (!project) {
    return message.reply(`❌ Cannot resolve project for ${repo}.`);
  }

  // Acknowledge in Discord
  const ack = await message.reply(`🔄 Running tests for ${repo}#${pr} (${branch})…`);
  log(`ack posted for ${repo}#${pr}`);

  try {
    const { stdout } = await runTest(repo, pr, branch, project);
    const reportMatch = stdout.match(/## (PASS|FAIL|WARN).*$/ms);
    const report = reportMatch ? reportMatch[0] : stdout.slice(-2000);

    // Post report as PR comment — propagate failure to the Discord ack so we
    // don't claim success when GitHub returned 401/422/etc.
    const gh = await postPRComment(repo, pr, report);
    if (gh.ok) {
      await ack.edit(`✅ Tests done for ${repo}#${pr} — report posted (HTTP ${gh.status})`);
    } else {
      await ack.edit(`⚠️ Tests ran for ${repo}#${pr}, but PR comment FAILED (HTTP ${gh.status}): ${gh.body.slice(0, 200)}`);
    }
    log(`done ${repo}#${pr} (gh=${gh.status})`);
  } catch (e) {
    await ack.edit(`❌ Test failed: ${e.message.slice(0, 500)}`);
    log(`FAIL ${repo}#${pr}: ${e.message}`);
  }
}

// --- Client ----------------------------------------------------------------

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

client.once(Events.ClientReady, c => {
  log(`logged in as ${c.user.tag} (id=${c.user.id})`);
  log(`watching ${channels.size} channels: ${[...channels.values()].map(c => c.name).join(', ')}`);
});

client.on(Events.MessageCreate, async message => {
  // Ignore self + bots
  if (message.author.bot) return;

  const channelCfg = channels.get(message.channelId);
  if (!channelCfg) return;  // not a watched channel

  const content = message.content.trim();

  // Command: retest → re-run last test for the latest PR in this channel
  if (content === '!retest' || content === 'retest') {
    log(`retest in ${message.channel.name}`);
    // Find last TEST_REQUEST in channel
    try {
      const recent = await message.channel.messages.fetch({ limit: 20 });
      const last = recent.find(m => TRIGGER_PATTERN.test(m.content));
      if (last) {
        const parsed = parseTestRequest(last.content);
        if (parsed) return handleTestRequest(last, channelCfg, parsed);
      }
      await message.reply('❌ No recent TEST_REQUEST found in this channel.');
    } catch (e) {
      log(`retest error: ${e.message}`);
    }
    return;
  }

  // Command: status → report listener health
  if (content === '!status' || content === 'status') {
    return message.reply(`✅ Hermes-Work Listener v${config.version} — watching ${channels.size} channels. Last message: ${new Date().toISOString()}`);
  }

  // Main trigger: TEST_REQUEST branch=X pr=Y
  const parsed = parseTestRequest(content);
  if (!parsed) return;

  await handleTestRequest(message, channelCfg, parsed);
});

client.on(Events.Error, err => log(`client error: ${err.message}`));

// --- Startup ---------------------------------------------------------------

loadDiscordToken();
loadGithubToken();
log('connecting to Discord...');
client.login(discordToken);

// Graceful shutdown
process.on('SIGINT', () => { log('SIGINT, shutting down'); client.destroy(); process.exit(0); });
process.on('SIGTERM', () => { log('SIGTERM, shutting down'); client.destroy(); process.exit(0); });