import test from 'node:test';
import assert from 'node:assert/strict';
import { UndoStack } from '../../src/core/undo.js';

test('LIFO, empty returns null', async () => {
  const s = new UndoStack(), order = [];
  assert.equal(s.canUndo, false);
  assert.equal(await s.undo(), null);
  s.push('one', async () => { order.push(1); return 'a'; });
  s.push('two', async () => { order.push(2); return 'b'; });
  assert.equal(s.peekLabel(), 'two');
  assert.deepEqual(await s.undo(), { label: 'two', result: 'b' });
  assert.deepEqual(await s.undo(), { label: 'one', result: 'a' });
  assert.deepEqual(order, [2, 1]);
  assert.equal(s.canUndo, false);
  assert.equal(s.peekLabel(), null);
});

test('caps at 100', async () => {
  const s = new UndoStack();
  for (let i = 0; i < 105; i++) s.push(String(i), async () => {});
  let n = 0;
  while (await s.undo()) n++;
  assert.equal(n, 100);
});
