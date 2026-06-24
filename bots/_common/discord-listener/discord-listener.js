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
  || '/tmp/gh-token-raw.txt';

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
    githubToken = fs.readFileSync(GITHUB_TOKEN_PATH, 'utf8').trim();
    if (!githubToken) throw new Error('empty file');
    log(`github token loaded (${githubToken.length} chars)`);
  } catch (e) {
    log(`WARN: cannot read github token: ${e.message}`);
  }
}

// --- Message Parsing -------------------------------------------------------

// Footer format: "TEST_REQUEST branch=wcms-1234 pr=440 repo=JUMO-GmbH-Co-KG/JUMO-Website-CMS"
const TRIGGER_PATTERN = /^(JUMO_)?TEST_REQUEST\s+branch=(\S+)\s+pr=(\d+)(?:\s+repo=(\S+))?/i;

function parseTestRequest(content) {
  const m = content.match(TRIGGER_PATTERN);
  if (!m) return null;
  return {
    prefix: (m[1] || '').toUpperCase() + 'TEST_REQUEST',
    branch: m[2],
    pr: m[3],
    repo: m[4] || null,  // null = use channel default
  };
}

// --- Bot Identification ----------------------------------------------------

function projectForRepo(repoFullName) {
  // SkyTechNerds/ha-soft-presence → ha-soft-presence
  // JUMO-GmbH-Co-KG/JUMO-Website-CMS → jumo
  const name = repoFullName.split('/')[1];
  if (name === 'JUMO-Website-CMS') return 'jumo';
  return name;  // for SkyTechNerds/ha-soft-presence etc.
}

// --- Test Invocation -------------------------------------------------------

function runTest(repoFullName, pr, branch, mode = 'collect') {
  const project = projectForRepo(repoFullName);
  const script = path.join(BOTS_DIR, project, 'test-pr.sh');
  if (!fs.existsSync(script)) {
    throw new Error(`No test script at ${script}`);
  }
  log(`running ${script} ${pr} ${branch} ${mode}`);
  const env = { ...process.env, REPO: repoFullName, PATH: process.env.PATH };
  const result = spawn('bash', [script, String(pr), branch, 'main', mode], {
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

async function postPRComment(repoFullName, pr, body) {
  if (!githubToken) {
    log('skipping PR comment: no github token');
    return;
  }
  const url = `https://api.github.com/repos/${repoFullName}/issues/${pr}/comments`;
  const payload = JSON.stringify({ body });
  const proc = spawn('curl', [
    '-s', '-X', 'POST', url,
    '-H', `Authorization: token ${githubToken}`,
    '-H', 'Content-Type: application/json',
    '-H', 'User-Agent: hermes-discord-listener',
    '-d', payload,
  ]);
  let out = '';
  for await (const chunk of proc.stdout) out += chunk;
  log(`PR comment post: ${out.slice(0, 200)}`);
}

// --- Main Handler ----------------------------------------------------------

async function handleTestRequest(message, channelCfg, parsed) {
  const repo = parsed.repo || channelCfg.repo;
  const { pr, branch } = parsed;

  // Acknowledge in Discord
  const ack = await message.reply(`🔄 Running tests for ${repo}#${pr} (${branch})…`);
  log(`ack posted for ${repo}#${pr}`);

  try {
    const { stdout } = await runTest(repo, pr, branch);
    const reportMatch = stdout.match(/## (PASS|FAIL|WARN).*$/ms);
    const report = reportMatch ? reportMatch[0] : stdout.slice(-2000);

    // Post report as PR comment
    await postPRComment(repo, pr, report);

    // Update Discord ack with result
    await ack.edit(`✅ Tests done for ${repo}#${pr}`);
    log(`done ${repo}#${pr}`);
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