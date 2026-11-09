// The bridge's T3 session token. Minted with the user's own `t3` CLI, stored 0600
// under ~/.config/t3code-wow, renewed a week before it expires.

import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { normalizeT3Origin } from './t3.js';

export const CONFIG_DIR = path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 't3code-wow');
export const TOKEN_FILE = path.join(CONFIG_DIR, 'token');

const RENEW_BEFORE_MS = 7 * 24 * 3600 * 1000;
const BRIDGE_SCOPES = ['orchestration:read', 'orchestration:operate'];
const OAUTH_ACCESS_TOKEN = 'urn:ietf:params:oauth:token-type:access_token';

export async function exchangePairingCode(origin, code) {
  const endpoint = new URL('/oauth/token', normalizeT3Origin(origin));
  const body = new URLSearchParams({
    grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token: code,
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: OAUTH_ACCESS_TOKEN,
    scope: BRIDGE_SCOPES.join(' '),
    client_label: 'WoW bridge Windows',
    client_device_type: 'desktop',
    client_os: 'Windows',
  });

  let response;
  try {
    response = await fetch(endpoint, {
      method: 'POST', body, redirect: 'error', signal: AbortSignal.timeout(8000),
    });
  } catch {
    throw new Error('Could not reach the T3 Code token endpoint. Check the server address and network access.');
  }
  if (response.status === 404) throw new Error('This T3 Code server cannot exchange pairing codes. Use a scoped session token.');
  if (!response.ok) throw new Error('T3 Code refused the pairing code. Create a fresh link with permission to read and operate threads.');

  const result = await response.json().catch(() => null);
  if (result?.token_type !== 'Bearer' || typeof result.access_token !== 'string'
    || !/^[A-Za-z0-9._~+/\-]+=*$/.test(result.access_token)) {
    throw new Error('T3 Code did not return a bearer session. Create a fresh pairing link and try again.');
  }
  const scopes = new Set(typeof result.scope === 'string' ? result.scope.trim().split(/\s+/) : []);
  if (scopes.size !== BRIDGE_SCOPES.length || BRIDGE_SCOPES.some((scope) => !scopes.has(scope))) {
    throw new Error('The T3 Code session must grant exactly read and operate permissions for threads.');
  }
  return result.access_token;
}

export function tokenClaims(token) {
  try {
    const [body] = token.split('.');
    return JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
}

export function findT3Cli() {
  const candidates = [
    process.env.T3_CLI,
    path.join(os.homedir(), '.local/bin/t3'),
    path.join(os.homedir(), '.t3/bin/t3'),
    '/usr/bin/t3',
    '/usr/local/bin/t3',
  ];
  for (const c of candidates) {
    if (c && fs.existsSync(c)) return c;
  }
  for (const dir of (process.env.PATH || '').split(':')) {
    const p = path.join(dir, 't3');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

export function mintToken({ label = 'WoW bridge' } = {}) {
  const cli = findT3Cli();
  if (!cli) return Promise.reject(new Error('could not find the `t3` command; open T3 Code once so it installs it'));
  const args = [
    'auth', 'session', 'issue',
    ...BRIDGE_SCOPES.flatMap((scope) => ['--scope', scope]),
    '--ttl', '30d',
    '--label', label,
    '--token-only',
  ];
  return new Promise((resolve, reject) => {
    execFile(cli, args, { timeout: 120000 }, (err, stdout, stderr) => {
      if (err) return reject(new Error(`t3 auth session issue failed: ${(stderr || err.message).trim()}`));
      const token = stdout.split('\n').map((s) => s.trim()).filter(Boolean).pop();
      if (!token || !tokenClaims(token)) return reject(new Error('t3 auth session issue printed no token'));
      fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
      fs.writeFileSync(TOKEN_FILE, token, { mode: 0o600 });
      resolve(token);
    });
  });
}

export function readToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, 'utf8').trim() || null;
  } catch {
    return null;
  }
}

// Returns a function the T3 client calls before connecting.
export function tokenProvider({ log = () => {} } = {}) {
  let minting = null;
  let forceRenew = false;
  const provider = async () => {
    if (process.env.T3_TOKEN?.trim()) return process.env.T3_TOKEN.trim();
    if (process.env.T3_ORIGIN) throw new Error('Set T3_TOKEN to a scoped session token from the T3 Code server');
    let token = readToken();
    const claims = token && tokenClaims(token);
    const expiring = !claims || (claims.exp && claims.exp - Date.now() < RENEW_BEFORE_MS);
    if (!token || expiring || forceRenew) {
      if (!minting) {
        log(token ? 'renewing the T3 session token' : 'minting a T3 session token');
        minting = mintToken().finally(() => {
          minting = null;
          forceRenew = false;
        });
      }
      try {
        token = await minting;
      } catch (err) {
        if (!token) throw err;
        log(`token renewal failed, using the old one: ${err.message}`);
      }
    }
    return token;
  };
  provider.invalidate = () => {
    forceRenew = true;
  };
  return provider;
}
