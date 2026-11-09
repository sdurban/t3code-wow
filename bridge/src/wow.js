// Finding the WoW: Forever install and the running client.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { findWindowsWowProcesses } from './windows.js';

const FLAVOR = '_forever_';
// Omarchy's Battle.net installer (omarchy-install-gaming-battlenet) uses this prefix.
export const OMARCHY_PREFIX = path.join(os.homedir(), 'Games/battlenet');

// Wine prefixes that might hold Battle.net, most likely first.
function candidateRoots() {
  const home = os.homedir();
  const roots = [];
  const add = (p) => p && !roots.includes(p) && roots.push(p);
  add(OMARCHY_PREFIX);
  add(process.env.WINEPREFIX);
  add(path.join(home, 'Games/battle-net'));
  add(path.join(home, 'Games/blizzard'));
  add(path.join(home, '.wine'));
  add(path.join(home, '.local/share/lutris/prefixes/battlenet'));
  // Heroic, Bottles and Steam (non-Steam game shortcut) prefixes.
  for (const base of [
    path.join(home, 'Games/Heroic/Prefixes/default'),
    path.join(home, '.var/app/com.usebottles.bottles/data/bottles/bottles'),
    path.join(home, '.local/share/bottles/bottles'),
    path.join(home, '.local/share/Steam/steamapps/compatdata'),
    path.join(home, '.steam/steam/steamapps/compatdata'),
  ]) {
    try {
      for (const d of fs.readdirSync(base)) {
        add(path.join(base, d));
        add(path.join(base, d, 'pfx'));
      }
    } catch {}
  }
  return roots.filter((r) => fs.existsSync(path.join(r, 'drive_c')));
}

// A Windows path ("C:/Games/World of Warcraft") inside a prefix, as a Linux path.
function winToLinux(root, win) {
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(win.trim());
  if (!m) return null;
  const drive = m[1].toLowerCase() === 'c' ? path.join(root, 'drive_c') : path.join(root, 'dosdevices', `${m[1].toLowerCase()}:`);
  return path.join(drive, ...m[2].split(/[\\/]+/).filter(Boolean));
}

// Where Battle.net says it put World of Warcraft (product.db), and where it installs
// new games by default (Battle.net.config). Covers installs outside Program Files.
function battlenetWowDirs(root) {
  const dirs = [];
  try {
    const db = fs.readFileSync(path.join(root, 'drive_c/ProgramData/Battle.net/Agent/product.db'), 'latin1');
    for (const m of db.matchAll(/[A-Za-z]:[\\/][^\x00-\x1f"]*?World of Warcraft(?=[\x00-\x1f"]|$)/g)) {
      const d = winToLinux(root, m[0]);
      if (d && !dirs.includes(d)) dirs.push(d);
    }
  } catch {}
  try {
    for (const user of fs.readdirSync(path.join(root, 'drive_c/users'))) {
      const cfg = JSON.parse(fs.readFileSync(path.join(root, 'drive_c/users', user, 'AppData/Roaming/Battle.net/Battle.net.config'), 'utf8'));
      const base = cfg?.Client?.Install?.DefaultInstallPath;
      const d = base && winToLinux(root, `${base}/World of Warcraft`);
      if (d && !dirs.includes(d)) dirs.push(d);
    }
  } catch {}
  return dirs;
}

function realDirKey(dir) {
  try {
    return fs.realpathSync.native(dir).toLowerCase();
  } catch {
    return path.resolve(dir).toLowerCase();
  }
}

export function windowsForeverDir(dir) {
  let root = path.resolve(dir);
  if (path.basename(root).toLowerCase() === 'addons' && path.basename(path.dirname(root)).toLowerCase() === 'interface') {
    root = path.dirname(path.dirname(root));
  }
  const forever = path.basename(root).toLowerCase() === FLAVOR ? root : path.join(root, FLAVOR);
  try {
    if (fs.statSync(path.join(forever, 'Wow.exe')).isFile()) return forever;
  } catch {}
  return null;
}

export function findWindowsWowInstalls(env = process.env, running = findWindowsWowProcesses()) {
  const dirs = running.map((p) => p.wowDir);
  const battleNet = env.ProgramData && path.join(env.ProgramData, 'Battle.net');
  if (battleNet) {
    try {
      const db = fs.readFileSync(path.join(battleNet, 'Agent', 'product.db'), 'utf8');
      // The launcher stores install paths as strings in its binary product records.
      for (const [value] of db.matchAll(/[A-Za-z]:[\\/][^\x00-\x1f"<>|?*]{1,512}/g)) dirs.push(value.trim());
    } catch {}
  }
  if (env.APPDATA) {
    try {
      const cfg = JSON.parse(fs.readFileSync(path.join(env.APPDATA, 'Battle.net', 'Battle.net.config'), 'utf8').replace(/^\uFEFF/, ''));
      const base = cfg?.Client?.Install?.DefaultInstallPath;
      if (typeof base === 'string' && path.isAbsolute(base)) dirs.push(path.join(base, 'World of Warcraft'));
    } catch {}
  }
  for (const base of [env.ProgramFiles, env['ProgramFiles(x86)'], env.ProgramW6432]) {
    if (base) dirs.push(path.join(base, 'World of Warcraft'));
  }

  const found = new Map();
  const wowOnly = new Set();
  for (const dir of dirs) {
    const forever = windowsForeverDir(dir);
    if (forever) {
      const key = realDirKey(forever);
      if (!found.has(key)) found.set(key, forever);
    } else if (path.basename(dir).toLowerCase() === 'world of warcraft' && fs.existsSync(dir)) {
      wowOnly.add(dir);
    }
  }
  return { forever: [...found.values()], wowOnly: [...wowOnly], prefixes: battleNet && fs.existsSync(battleNet) ? [battleNet] : [] };
}

// { forever: [...WoW: Forever folders], wowOnly: [...WoW installs without Forever], prefixes: [...prefixes with Battle.net] }
export function findWowInstalls() {
  if (process.platform === 'win32') return findWindowsWowInstalls();
  const forever = [];
  const wowOnly = [];
  const roots = candidateRoots();
  for (const root of roots) {
    const wowDirs = [
      ...battlenetWowDirs(root),
      path.join(root, 'drive_c/Program Files (x86)/World of Warcraft'),
      path.join(root, 'drive_c/Program Files/World of Warcraft'),
    ];
    for (const wow of wowDirs) {
      if (!fs.existsSync(wow)) continue;
      const dir = path.join(wow, FLAVOR);
      if (fs.existsSync(path.join(dir, 'Wow.exe')) || fs.existsSync(path.join(dir, 'Interface'))) {
        if (!forever.includes(dir)) forever.push(dir);
      } else if (!wowOnly.includes(wow)) {
        wowOnly.push(wow);
      }
    }
  }
  const battlenet = roots.filter((r) => ['drive_c/ProgramData/Battle.net', 'drive_c/Program Files (x86)/Battle.net', 'drive_c/Program Files/Battle.net']
    .some((d) => fs.existsSync(path.join(r, d))));
  return { forever, wowOnly: wowOnly.filter((w) => !forever.some((f) => f.startsWith(w + path.sep))), prefixes: battlenet };
}

export function findWowDirs() {
  return findWowInstalls().forever;
}

export function addonsDir(wowDir) {
  return path.join(wowDir, 'Interface', 'AddOns');
}

// The running Forever client: { pid, startTicks } or null. The start time
// distinguishes a restarted client that happens to reuse a pid.
export function findWowProcess(wowDir) {
  if (process.platform === 'win32') {
    const key = typeof wowDir === 'string' && wowDir && realDirKey(wowDir);
    return findWindowsWowProcesses().find((p) => !key || realDirKey(p.wowDir) === key) || null;
  }
  let entries;
  try {
    entries = fs.readdirSync('/proc');
  } catch {
    return null;
  }
  for (const e of entries) {
    if (!/^\d+$/.test(e)) continue;
    let cmd;
    try {
      cmd = fs.readFileSync(`/proc/${e}/cmdline`, 'latin1');
    } catch {
      continue;
    }
    if (!/_forever_[\\/]+Wow\.exe/i.test(cmd)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${e}/stat`, 'latin1');
      const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
      return { pid: Number(e), startTicks: Number(fields[19]) };
    } catch {
      return { pid: Number(e), startTicks: 0 };
    }
  }
  return null;
}

export function processKey(p) {
  return p ? `${p.pid}:${p.startTicks}` : null;
}
