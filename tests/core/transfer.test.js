import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir, touch } from '../helpers.js';
import { transfer } from '../../src/core/transfer.js';

const ls = async (d) => (await readdir(d)).sort();
const setup = async () => {
  const root = await tmpdir();
  const src = join(root, 'src'), dest = join(root, 'dest'), trashDir = join(root, 'trash');
  await mkdir(src); await mkdir(dest);
  return { src, dest, trashDir };
};

test('copy with clash and keepBoth gives "Brand-Guide 2.pdf"', async () => {
  const { src, dest, trashDir } = await setup();
  const f = await touch(src, 'Brand-Guide.pdf', 'new'); await touch(dest, 'Brand-Guide.pdf', 'old');
  const r = await transfer([f], dest, { mode: 'copy', trashDir, resolve: async () => ({ choice: 'keepBoth', applyToAll: false }) });
  assert.deepEqual(await ls(dest), ['Brand-Guide 2.pdf', 'Brand-Guide.pdf']);
  assert.equal(r.results[0].action, 'copied');
  assert.equal(await readFile(join(dest, 'Brand-Guide.pdf'), 'utf8'), 'old');
  assert.deepEqual(await ls(src), ['Brand-Guide.pdf']);
});

test('replace trashes the old file; undo brings it back', async () => {
  const { src, dest, trashDir } = await setup();
  const f = await touch(src, 'a.txt', 'new'); await touch(dest, 'a.txt', 'old');
  const r = await transfer([f], dest, { mode: 'copy', trashDir, resolve: async () => ({ choice: 'replace', applyToAll: false }) });
  assert.equal(r.results[0].action, 'replaced');
  assert.equal(await readFile(join(dest, 'a.txt'), 'utf8'), 'new');
  assert.equal((await ls(trashDir)).length, 1);
  const u = await r.undo();
  assert.equal(u.failed.length, 0);
  assert.equal(await readFile(join(dest, 'a.txt'), 'utf8'), 'old');
});

test('applyToAll asks once for 3 clashes', async () => {
  const { src, dest, trashDir } = await setup();
  const fs = [];
  for (const n of ['a.txt', 'b.txt', 'c.txt']) { fs.push(await touch(src, n)); await touch(dest, n); }
  let asked = 0;
  const r = await transfer(fs, dest, { mode: 'copy', trashDir, resolve: async () => { asked++; return { choice: 'skip', applyToAll: true }; } });
  assert.equal(asked, 1);
  assert.deepEqual(r.results.map((x) => x.action), ['skipped', 'skipped', 'skipped']);
});

test('stop halts before the clashing item and leaves the rest', async () => {
  const { src, dest, trashDir } = await setup();
  const a = await touch(src, 'a.txt'), b = await touch(src, 'b.txt'), c = await touch(src, 'c.txt');
  await touch(dest, 'b.txt');
  const r = await transfer([a, b, c], dest, { mode: 'move', trashDir, resolve: async () => ({ choice: 'stop', applyToAll: false }) });
  assert.equal(r.stopped, true);
  assert.deepEqual(r.results.map((x) => x.action), ['moved']);
  assert.deepEqual(await ls(src), ['b.txt', 'c.txt']);
  assert.deepEqual(await ls(dest), ['a.txt', 'b.txt']);
});

test('moving a folder into itself or its child throws and moves nothing', async () => {
  const { src, dest, trashDir } = await setup();
  await touch(src, 'a/b/f.txt'); await touch(src, 'z.txt');
  const a = join(src, 'a');
  await assert.rejects(() => transfer([join(src, 'z.txt'), a], join(a, 'b'), { mode: 'move', trashDir }), { message: 'Can\'t move “a” into itself' });
  await assert.rejects(() => transfer([a], a, { mode: 'move', trashDir }), /into itself/);
  assert.deepEqual(await ls(src), ['a', 'z.txt']);
  assert.deepEqual(await ls(join(a, 'b')), ['f.txt']);
});

test('undo of a move restores original paths; same-folder move is a no-op', async () => {
  const { src, dest, trashDir } = await setup();
  const f = await touch(src, 'a.txt'), g = await touch(dest, 'g.txt');
  const r = await transfer([f, g], dest, { mode: 'move', trashDir });
  assert.equal(r.results.length, 1);
  assert.deepEqual(await ls(dest), ['a.txt', 'g.txt']);
  await r.undo();
  assert.deepEqual(await ls(src), ['a.txt']);
  assert.deepEqual(await ls(dest), ['g.txt']);
});

test('undo of a copy trashes the copies', async () => {
  const { src, dest, trashDir } = await setup();
  const f = await touch(src, 'a.txt');
  const r = await transfer([f], dest, { mode: 'copy', trashDir });
  await r.undo();
  assert.deepEqual(await ls(dest), []);
  assert.deepEqual(await ls(src), ['a.txt']);
  assert.equal((await ls(trashDir)).length, 1);
});

test('progress ends with itemsDone === itemsTotal; abort signal stops', async () => {
  const { src, dest, trashDir } = await setup();
  const fs = [await touch(src, 'a.txt', '12345'), await touch(src, 'd/b.txt', '123')];
  const ev = [];
  await transfer(fs, dest, { mode: 'copy', trashDir, onProgress: (p) => ev.push(p) });
  const last = ev.at(-1);
  assert.equal(last.itemsDone, 2); assert.equal(last.itemsTotal, 2);
  assert.equal(last.bytesDone, last.bytesTotal);
  const ac = new AbortController(); ac.abort();
  const r = await transfer([await touch(src, 'e.txt')], dest, { mode: 'copy', trashDir, signal: ac.signal });
  assert.equal(r.stopped, true); assert.equal(r.results.length, 0);
});
