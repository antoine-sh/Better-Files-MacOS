import test from 'node:test';
import assert from 'node:assert/strict';
import { KINDS, kindOf, isDownloading, splitExt, formatBytes } from '../../src/core/kinds.js';

test('kindOf', () => {
  assert.equal(kindOf('a.PDF'), 'PDFs');
  assert.equal(kindOf('Screenshot 2026-11-01 at 10.00.00.png'), 'Screenshots');
  assert.equal(kindOf('x.png'), 'Images');
  assert.equal(kindOf('x.dmg'), 'Installers');
  assert.equal(kindOf('x.tar.gz'), 'Archives');
  assert.equal(kindOf('x.mp4'), 'Videos');
  assert.equal(kindOf('x.mp3'), 'Audio');
  assert.equal(kindOf('x.docx'), 'Documents');
  assert.equal(kindOf('noext'), 'Other');
  assert.ok(KINDS.includes('Other'));
});

test('isDownloading', () => {
  assert.ok(isDownloading('a.crdownload'));
  assert.ok(isDownloading('a.PART'));
  assert.ok(!isDownloading('a.pdf'));
});

test('splitExt', () => {
  assert.deepEqual(splitExt('a b.tar.gz'), ['a b', '.tar.gz']);
  assert.deepEqual(splitExt('.env'), ['.env', '']);
  assert.deepEqual(splitExt('report.pdf'), ['report', '.pdf']);
  assert.deepEqual(splitExt('noext'), ['noext', '']);
  assert.deepEqual(splitExt('trailing.'), ['trailing.', '']);
});

test('formatBytes', () => {
  assert.equal(formatBytes(0), '0 bytes');
  assert.equal(formatBytes(999), '999 bytes');
  assert.equal(formatBytes(1200), '1.2 KB');
  assert.equal(formatBytes(1.2e9), '1.2 GB');
});
