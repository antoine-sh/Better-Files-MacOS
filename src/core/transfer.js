import { lstat, cp } from 'node:fs/promises';
import { join, basename, dirname, resolve as abs, sep } from 'node:path';
import { uniqueName, trash, restore, move, dirSize } from './fsops.js';

const exists = (p) => lstat(p).then(() => true, () => false);

export async function transfer(sources, destDir, { mode, trashDir, resolve, onProgress, signal }) {
  destDir = abs(destDir);
  for (const s of sources) {
    const a = abs(s);
    if (destDir === a || destDir.startsWith(a + sep)) throw new Error(`Can't move “${basename(a)}” into itself`);
  }
  const sizes = [];
  for (const s of sources) {
    const l = await lstat(s);
    sizes.push(l.isDirectory() ? (await dirSize(s)).bytes : l.size);
  }
  const bytesTotal = sizes.reduce((a, b) => a + b, 0);
  const results = [], made = [], replaced = [];
  let stopped = false, remembered = null, bytesDone = 0, itemsDone = 0;
  const progress = (currentName) => onProgress?.({ currentName, bytesDone, bytesTotal, itemsDone, itemsTotal: sources.length });

  for (let i = 0; i < sources.length; i++) {
    const from = abs(sources[i]), name = basename(from);
    if (signal?.aborted) { stopped = true; break; }
    progress(name);
    let to = join(destDir, name), action = mode === 'move' ? 'moved' : 'copied';
    if (mode === 'move' && dirname(from) === destDir) { itemsDone++; bytesDone += sizes[i]; continue; } // already here
    if (await exists(to)) {
      // copying onto itself can only mean "make another one"
      const a = to === from ? { choice: 'keepBoth' } : remembered ?? await resolve({ name, destDir, remaining: sources.length - i - 1 });
      if (a.applyToAll && to !== from) remembered = a;
      if (a.choice === 'stop') { stopped = true; break; }
      if (a.choice === 'skip') {
        results.push({ from, to, action: 'skipped' });
        itemsDone++; bytesDone += sizes[i]; progress(name);
        continue;
      }
      if (a.choice === 'keepBoth') to = join(destDir, await uniqueName(destDir, name));
      else { replaced.push(...await trash([to], trashDir)); action = 'replaced'; }
    }
    if (mode === 'move') await move(from, to);
    else await cp(from, to, { recursive: true, errorOnExist: true, force: false });
    made.push({ from, to });
    results.push({ from, to, action });
    itemsDone++; bytesDone += sizes[i]; progress(name);
  }

  const undo = async () => {
    const r = mode === 'move' ? await restore([...made].reverse()) : { restored: [], failed: [] };
    if (mode === 'copy') await trash(made.map((m) => m.to), trashDir);
    const back = await restore([...replaced].reverse()); // slots are free again now
    return { restored: [...r.restored, ...back.restored], failed: [...r.failed, ...back.failed] };
  };
  return { results, stopped, undo };
}
