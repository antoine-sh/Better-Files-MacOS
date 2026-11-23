import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, chmod, readdir, readFile, symlink, access } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir, touch } from '../helpers.js';
import * as fo from '../../src/core/fsops.js';

const exists = (p) => access(p).then(() => true, () => false);

test('uniqueName', async () => {
  const d = await tmpdir();
  assert.equal(await fo.uniqueName(d, 'a b.tar.gz'), 'a b.tar.gz');
  await touch(d, 'a b.tar.gz');
  assert.equal(await fo.uniqueName(d, 'a b.tar.gz'), 'a b 2.tar.gz');
  await touch(d, 'a b 2.tar.gz');
  assert.equal(await fo.uniqueName(d, 'a b.tar.gz'), 'a b 3.tar.gz');
});

test('newFolder', async () => {
  const d = await tmpdir();
  assert.equal(await fo.newFolder(d), join(d, 'untitled folder'));
  assert.equal(await fo.newFolder(d), join(d, 'untitled folder 2'));
});

test('duplicate file and folder', async () => {
  const d = await tmpdir();
  const p = await touch(d, 'report.pdf', 'hi');
  assert.equal(await fo.duplicate(p), join(d, 'report copy.pdf'));
  assert.equal(await fo.duplicate(p), join(d, 'report copy 2.pdf'));
  assert.equal(await readFile(join(d, 'report copy.pdf'), 'utf8'), 'hi');
  await touch(d, 'dir/in.txt', 'q');
  const c = await fo.duplicate(join(d, 'dir'));
  assert.equal(c, join(d, 'dir copy'));
  assert.equal(await readFile(join(c, 'in.txt'), 'utf8'), 'q');
});

test('makeAlias', async () => {
  const d = await tmpdir();
  const p = await touch(d, 'a.txt', 'z');
  const a = await fo.makeAlias(p);
  assert.equal(a, join(d, 'a alias.txt'));
  assert.equal(await readFile(a, 'utf8'), 'z'); // symlink resolves
  assert.equal((await fo.listDir(d)).find((e) => e.name === 'a alias.txt').isSymlink, true);
});

test('renameItem', async () => {
  const d = await tmpdir();
  const p = await touch(d, 'a.txt');
  assert.equal(await fo.renameItem(p, 'b “q” é.txt'), join(d, 'b “q” é.txt'));
  await touch(d, 'c.txt');
  await assert.rejects(fo.renameItem(join(d, 'b “q” é.txt'), 'c.txt'), { code: 'EEXIST' });
  await assert.rejects(fo.renameItem(join(d, 'c.txt'), 'x/y'));
  await assert.rejects(fo.renameItem(join(d, 'c.txt'), ''));
});

test('trash and restore round-trip', async () => {
  const d = await tmpdir(), t = join(d, '.Trash');
  const a = await touch(d, 'a.txt', 'A'), b = await touch(d, 'sub/a.txt', 'B');
  const moves = await fo.trash([a, b], t);
  assert.equal(moves.length, 2);
  assert.ok(!(await exists(a)) && !(await exists(b)));
  assert.equal((await readdir(t)).length, 2); // same basename, unique names
  assert.deepEqual(await fo.trashSummary(t), { count: 2, bytes: 2 });
  const r = await fo.restore(moves);
  assert.deepEqual(r, { restored: [a, b], failed: [] });
  assert.equal(await readFile(b, 'utf8'), 'B');
});

test('restore never overwrites', async () => {
  const d = await tmpdir(), t = join(d, '.Trash');
  const a = await touch(d, 'a.txt', 'old');
  const moves = await fo.trash([a], t);
  await touch(d, 'a.txt', 'new');
  const r = await fo.restore(moves);
  assert.equal(r.restored.length, 0);
  assert.equal(r.failed[0].path, a);
  assert.equal(await readFile(a, 'utf8'), 'new');
  assert.equal(await readFile(moves[0].to, 'utf8'), 'old');
});

test('restore recreates missing parent', async () => {
  const d = await tmpdir(), t = join(d, '.Trash');
  const a = await touch(d, 'p/a.txt');
  const moves = await fo.trash([a], t);
  await fo.trash([join(d, 'p')], t);
  assert.equal((await fo.restore(moves)).restored.length, 1);
});

test('emptyTrash', async () => {
  const d = await tmpdir(), t = join(d, '.Trash');
  await fo.trash([await touch(d, 'a', 'abc'), await touch(d, 'f/b', 'de')], t);
  assert.deepEqual(await fo.emptyTrash(t), { count: 2, bytes: 5 });
  assert.deepEqual(await fo.trashSummary(t), { count: 0, bytes: 0 });
  assert.deepEqual(await fo.emptyTrash(join(d, 'nope')), { count: 0, bytes: 0 });
});

test('listDir entries and hidden', async () => {
  const d = await tmpdir();
  await touch(d, 'a.pdf', 'xyz'); await touch(d, '.hid'); await mkdir(join(d, 'f'));
  const l = await fo.listDir(d);
  assert.deepEqual(l.map((e) => e.name).sort(), ['a.pdf', 'f']);
  const a = l.find((e) => e.name === 'a.pdf');
  assert.equal(a.kind, 'PDFs'); assert.equal(a.size, 3); assert.equal(a.path, join(d, 'a.pdf'));
  assert.equal(a.addedMs, a.birthtimeMs);
  assert.equal(l.find((e) => e.name === 'f').kind, 'Folder');
  const all = await fo.listDir(d, { showHidden: true });
  assert.equal(all.find((e) => e.name === '.hid').hidden, true);
  assert.equal(all.length, 3);
});

test('listDir EACCES', { skip: process.getuid?.() === 0 && 'root bypasses chmod' }, async () => {
  const d = await tmpdir(), l = join(d, 'locked');
  await mkdir(l); await chmod(l, 0o000);
  try { await assert.rejects(fo.listDir(l), { code: 'EACCES' }); } finally { await chmod(l, 0o755); }
});

test('dirSize does not follow symlink loops, honours cap', async () => {
  const d = await tmpdir();
  await touch(d, 'a/x', '12345'); await touch(d, 'a/b/y', '123');
  await symlink(d, join(d, 'a', 'loop'));
  const r = await fo.dirSize(d);
  assert.equal(r.bytes, 8);
  assert.ok(r.items >= 2);
  const capped = await fo.dirSize(d, { maxEntries: 1 });
  assert.ok(capped.items <= 2);
});

test('diskInfo', async () => {
  const i = await fo.diskInfo(await tmpdir());
  assert.ok(i.total > 0 && i.free >= 0 && i.free <= i.total);
});
