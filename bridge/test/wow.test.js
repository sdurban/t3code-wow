import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Fake home with Wine prefixes, set before wow.js reads it.
const home = fs.mkdtempSync(path.join(os.tmpdir(), 't3wow-home-'));
process.env.HOME = home;
delete process.env.WINEPREFIX;
const { findWowInstalls, findWindowsWowInstalls, windowsForeverDir } = await import('../src/wow.js');

function touch(p, content = '') {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
}

function reset() {
  fs.rmSync(path.join(home, 'Games'), { recursive: true, force: true });
  fs.rmSync(path.join(home, '.local'), { recursive: true, force: true });
}

const omarchy = () => path.join(home, 'Games/battlenet');
const linux = { skip: process.platform !== 'linux' && 'requires Linux Wine prefixes' };
const windows = { skip: process.platform !== 'win32' && 'requires Windows paths' };

test("finds Forever in Omarchy's Battle.net prefix", linux, () => {
  reset();
  touch(path.join(omarchy(), 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'));
  touch(path.join(omarchy(), 'drive_c/Program Files (x86)/World of Warcraft/_forever_/Wow.exe'));
  assert.deepEqual(findWowInstalls().forever, [path.join(omarchy(), 'drive_c/Program Files (x86)/World of Warcraft/_forever_')]);
});

test("finds a custom install folder from Battle.net's records, including another drive", linux, () => {
  reset();
  touch(path.join(omarchy(), 'drive_c/ProgramData/Battle.net/Agent/product.db'),
    'junk\x00\x12(C:/Games/World of Warcraft\x00wowf\x00\x12"D:\\Blizzard\\World of Warcraft"');
  touch(path.join(omarchy(), 'drive_c/Games/World of Warcraft/_forever_/Wow.exe'));
  // D: is a dosdevices link to somewhere else on disk.
  const elsewhere = path.join(home, 'Games/disk-d');
  touch(path.join(elsewhere, 'Blizzard/World of Warcraft/_retail_/Wow.exe'));
  fs.mkdirSync(path.join(omarchy(), 'dosdevices'), { recursive: true });
  fs.symlinkSync(elsewhere, path.join(omarchy(), 'dosdevices/d:'));
  const r = findWowInstalls();
  assert.deepEqual(r.forever, [path.join(omarchy(), 'drive_c/Games/World of Warcraft/_forever_')]);
  assert.deepEqual(r.wowOnly, [path.join(omarchy(), 'dosdevices/d:/Blizzard/World of Warcraft')]);
});

test('tells WoW without Forever apart from no WoW at all, and ignores other games\' prefixes', linux, () => {
  reset();
  touch(path.join(omarchy(), 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'));
  touch(path.join(omarchy(), 'drive_c/Program Files (x86)/World of Warcraft/_retail_/Wow.exe'));
  let r = findWowInstalls();
  assert.equal(r.forever.length, 0);
  assert.deepEqual(r.wowOnly, [path.join(omarchy(), 'drive_c/Program Files (x86)/World of Warcraft')]);

  reset();
  touch(path.join(omarchy(), 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'));
  touch(path.join(home, '.local/share/Steam/steamapps/compatdata/1091500/pfx/drive_c/windows/win.ini'));
  r = findWowInstalls();
  assert.deepEqual([r.forever.length, r.wowOnly.length], [0, 0]);
  assert.deepEqual(r.prefixes, [omarchy()], 'only prefixes that really hold Battle.net');
});

test('discovers Windows installs from the running client, Battle.net and standard paths', windows, () => {
  const data = path.join(home, 'ProgramData');
  const appData = path.join(home, 'Roaming');
  const programFiles = path.join(home, 'Program Files');
  const custom = path.join(home, 'Custom Games', 'WoW');
  const standard = path.join(programFiles, 'World of Warcraft');
  const onlyRetail = path.join(home, 'Retail', 'World of Warcraft');
  const running = path.join(home, 'Running Client', '_forever_');
  touch(path.join(data, 'Battle.net', 'Agent', 'product.db'),
    `binary\x00${custom.replaceAll('\\', '/')}\x00other product\x00${onlyRetail}\x00`);
  touch(path.join(appData, 'Battle.net', 'Battle.net.config'),
    JSON.stringify({ Client: { Install: { DefaultInstallPath: programFiles } } }));
  for (const dir of [running, path.join(custom, '_forever_'), path.join(standard, '_forever_')]) {
    touch(path.join(dir, 'Wow.exe'));
  }
  touch(path.join(onlyRetail, '_retail_', 'Wow.exe'));

  const found = findWindowsWowInstalls({
    ProgramData: data, APPDATA: appData, ProgramFiles: programFiles, ProgramW6432: programFiles,
  }, [{ wowDir: running }]);
  assert.deepEqual(found.forever, [running, path.join(custom, '_forever_'), path.join(standard, '_forever_')]);
  assert.deepEqual(found.wowOnly, [onlyRetail]);
  assert.deepEqual(found.prefixes, [path.join(data, 'Battle.net')]);
  assert.equal(windowsForeverDir(path.join(standard, '_forever_', 'Interface', 'AddOns')), path.join(standard, '_forever_'));
  assert.equal(windowsForeverDir(path.join(onlyRetail, '_retail_', 'Interface', 'AddOns')), null);
});
