import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdir } from 'node:fs/promises';
import { tmpdir, touch } from '../helpers.js';
import { validateName, extensionChange, planBatchRename, applyBatchRename } from '../../src/core/rename.js';

test('validateName', () => {
  assert.equal(validateName('a/b'), 'Names can\'t contain / or :');
  assert.equal(validateName('a:b'), 'Names can\'t contain / or :');
  assert.equal(validateName('.x'), 'Names can\'t start with a dot');
  assert.equal(validateName(''), 'Name can\'t be empty');
  assert.equal(validateName('é'.repeat(128)), 'Name is too long');
  assert.equal(validateName('é'.repeat(127)), null);
  assert.equal(validateName('a b “q”.tar.gz'), null);
});

test('extensionChange', () => {
  assert.deepEqual(extensionChange('a.pdf', 'a.docx'), { from: '.pdf', to: '.docx' });
  assert.equal(extensionChange('a.pdf', 'b.pdf'), null);
  assert.deepEqual(extensionChange('a.tar.gz', 'a.zip'), { from: '.tar.gz', to: '.zip' });
});

test('number rule pads to two digits and keeps extensions', () => {
  const p = planBatchRename(['x.jpg', 'y.jpg'], { type: 'number', name: 'Lisbon' }, new Set(['x.jpg', 'y.jpg']));
  assert.deepEqual(p.map((r) => r.to), ['Lisbon 01.jpg', 'Lisbon 02.jpg']);
  assert.ok(p.every((r) => !r.error));
  assert.equal(planBatchRename(['a.png'], { type: 'number', name: 'N', start: 10 }, new Set())[0].to, 'N 10.png');
});

test('replace and add rules', () => {
  const r = planBatchRename(['IMG a.tar.gz'], { type: 'replace', find: 'IMG', with: 'Trip' }, new Set());
  assert.equal(r[0].to, 'Trip a.tar.gz');
  const b = planBatchRename(['a.txt'], { type: 'add', text: 'x-', where: 'before' }, new Set());
  assert.equal(b[0].to, 'x-a.txt');
  const a = planBatchRename(['a.txt'], { type: 'add', text: '-x', where: 'after' }, new Set());
  assert.equal(a[0].to, 'a-x.txt');
});

test('errors: duplicate, already in folder, invalid, downloading', () => {
  const d3 = planBatchRename(['a.txt', 'b.txt'], { type: 'number', name: 'Same', start: 1 }, new Set());
  assert.ok(d3.every((r) => !r.error));
  const d4 = planBatchRename(['a.txt', 'b.txt'], { type: 'replace', find: 'b', with: 'a' }, new Set(['a.txt', 'b.txt']));
  assert.equal(d4[1].error, 'Duplicate name');
  assert.equal(d4[0].error, 'Duplicate name');
  const ex = planBatchRename(['a.txt'], { type: 'replace', find: 'a', with: 'b' }, new Set(['a.txt', 'b.txt']));
  assert.equal(ex[0].error, 'Already in this folder');
  const bad = planBatchRename(['a.txt'], { type: 'replace', find: 'a', with: '/' }, new Set());
  assert.equal(bad[0].error, 'Names can\'t contain / or :');
  const dl = planBatchRename(['a.crdownload'], { type: 'add', text: 'x', where: 'before' }, new Set());
  assert.equal(dl[0].error, 'Still downloading');
});

test('applyBatchRename applies only rows without errors; undo restores', async () => {
  const dir = await tmpdir();
  await touch(dir, 'a.txt'); await touch(dir, 'b.txt');
  const plan = [{ from: 'a.txt', to: 'c.txt', error: null }, { from: 'b.txt', to: 'd.txt', error: 'Duplicate name' }];
  const { renamed, undo } = await applyBatchRename(dir, plan);
  assert.equal(renamed, 1);
  assert.deepEqual((await readdir(dir)).sort(), ['b.txt', 'c.txt']);
  const res = await undo();
  assert.equal(res.restored.length, 1);
  assert.deepEqual((await readdir(dir)).sort(), ['a.txt', 'b.txt']);
});
