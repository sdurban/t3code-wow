// Windows PowerShell hosts the built-in Win32 and .NET APIs for game discovery
// and screen capture. Keep the capture worker alive between polls.
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';

const POWERSHELL = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const POWERSHELL_ARGS = ['-NoLogo', '-NoProfile', '-NonInteractive'];

export function findWindowsWowProcesses() {
  try {
    const script = String.raw`
      [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
      foreach ($game in (Get-Process -Name Wow -ErrorAction SilentlyContinue)) {
        try {
          $exe = $game.Path
          if ($exe -match '[\\/]_forever_[\\/]Wow\.exe$') {
            $start = ([DateTimeOffset]$game.StartTime).ToUnixTimeMilliseconds()
            [Console]::WriteLine('{0} {1} {2}', $game.Id, $start, $exe)
          }
        } catch {}
      }`;
    const output = execFileSync(POWERSHELL, [...POWERSHELL_ARGS, '-Command', script], {
      windowsHide: true, encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'],
    });
    return output.trim().split(/\r?\n/).flatMap((line) => {
      const match = /^(\d+) (\d+) (.+)$/.exec(line);
      return match ? [{ pid: Number(match[1]), startTicks: Number(match[2]), wowDir: path.dirname(match[3]) }] : [];
    });
  } catch {}
  return [];
}

export class WindowsCapture {
  constructor() {
    this.child = null;
    this.nextId = 0;
    this.pending = new Map();
  }

  start() {
    const script = fs.readFileSync(new URL('./capture-windows.ps1', import.meta.url), 'utf8');
    const child = spawn(POWERSHELL, [...POWERSHELL_ARGS, '-Command', script], {
      windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child = child;
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      stderr = (stderr + chunk).slice(-2048);
    });
    createInterface({ input: child.stdout }).on('line', (line) => {
      const reply = /^(\d+) (ok|hidden|no-window|error)(?: (.*))?$/.exec(line);
      if (!reply) return;
      const [, id, status, payload] = reply;
      const pending = this.pending.get(Number(id));
      if (!pending) return;
      this.pending.delete(Number(id));
      clearTimeout(pending.timer);
      if (status === 'error') pending.reject(new Error(payload || 'Windows capture failed'));
      else pending.resolve({ status, data: status === 'ok' ? Buffer.from(payload, 'base64') : undefined });
    });
    const fail = (err) => {
      if (this.child === child) this.close(err);
    };
    child.once('error', fail);
    child.stdin.on('error', fail);
    child.once('close', (code) => fail(new Error(stderr.trim() || 'Windows capture stopped (exit ' + code + ')')));
    return child;
  }

  request(pid, width, height) {
    if (!pid) return Promise.resolve({ status: 'no-window' });
    const child = this.child || this.start();
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.close(new Error('Windows capture timed out')), 10000);
      this.pending.set(id, { resolve, reject, timer });
      child.stdin.write([id, pid, width, height].join(' ') + '\n');
    });
  }

  close(err = new Error('Windows capture closed')) {
    const child = this.child;
    this.child = null;
    child?.kill();
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(err);
    }
    this.pending.clear();
  }
}
