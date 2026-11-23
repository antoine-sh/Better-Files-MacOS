import { readdir, stat, lstat, mkdir, rename, cp, rm, symlink, statfs } from 'node:fs/promises';
import { join, dirname, basename } from 'node:path';
import { kindOf, splitExt } from './kinds.js';

const exists = (p) => lstat(p).then(() => true, () => false);

export async function listDir(dir, { showHidden = false } = {}) {
  const names = await readdir(dir); // EACCES/EPERM propagate: UI shows the locked-folder screen
  const out = [];
  for (const name of names) {
    const hidden = name.startsWith('.');
    if (hidden && !showHidden) continue;
    const path = join(dir, name);
    try {
      const l = await lstat(path);
      const s = l.isSymbolicLink() ? await stat(path).catch(() => l) : l; // broken link: describe the link
      const isDir = s.isDirectory();
      out.push({
        name, path, isDir, isSymlink: l.isSymbolicLink(), size: s.size, mtimeMs: s.mtimeMs,
        birthtimeMs: s.birthtimeMs,
        addedMs: s.birthtimeMs, // shortcut: macOS "Date Added" lives in Spotlight metadata; birthtime is close enough for downloads
        kind: isDir ? 'Folder' : kindOf(name), hidden,
      });
    } catch { /* vanished between readdir and stat */ }
  }
  return out;
}

export async function uniqueName(dir, name) {
  if (!(await exists(join(dir, name)))) return name;
  const [base, ext] = splitExt(name);
  for (let n = 2; ; n++) {
    const c = `${base} ${n}${ext}`;
    if (!(await exists(join(dir, c)))) return c;
  }
}

export async function newFolder(dir) {
  const p = join(dir, await uniqueName(dir, 'untitled folder'));
  await mkdir(p);
  return p;
}

export async function duplicate(path) {
  const dir = dirname(path), [base, ext] = splitExt(basename(path));
  const to = join(dir, await uniqueName(dir, `${base} copy${ext}`));
  await cp(path, to, { recursive: true, errorOnExist: true, force: false });
  return to;
}

export async function makeAlias(path) {
  const dir = dirname(path), [base, ext] = splitExt(basename(path));
  const to = join(dir, await uniqueName(dir, `${base} alias${ext}`));
  await symlink(path, to); // shortcut: symlink, not a macOS alias file; upgrade if bookmarks must survive moves
  return to;
}

// case-insensitive filesystems: Report.txt and report.txt are one inode, so that's a rename, not a clash
async function sameFile(a, b) {
  const [x, y] = await Promise.all([lstat(a), lstat(b)]);
  return x.dev === y.dev && x.ino === y.ino;
}

export async function renameItem(path, newName) {
  if (!newName || newName === '.' || newName === '..' || /[/\\]/.test(newName)) throw Object.assign(new Error('Invalid name'), { code: 'EINVAL' });
  const to = join(dirname(path), newName);
  if (to !== path && await exists(to) && !(await sameFile(path, to))) throw Object.assign(new Error(`“${newName}” already exists`), { code: 'EEXIST' });
  await rename(path, to);
  return to;
}

// rename, falling back to copy+remove across devices
async function move(from, to) {
  try { await rename(from, to); } catch (e) {
    if (e.code !== 'EXDEV') throw e;
    await cp(from, to, { recursive: true, errorOnExist: true, force: false });
    await rm(from, { recursive: true });
  }
}

// shortcut: other volumes have their own .Trashes; upgrade to shell.trashItem + no-undo for those.
export async function trash(paths, trashDir) {
  await mkdir(trashDir, { recursive: true });
  const moves = [];
  for (const from of paths) {
    const to = join(trashDir, await uniqueName(trashDir, basename(from)));
    await move(from, to);
    moves.push({ from, to });
  }
  return moves;
}

export async function restore(moves) {
  const restored = [], failed = [];
  for (const { from, to } of moves) {
    try {
      if (await exists(from)) { failed.push({ path: from, reason: 'An item with that name already exists' }); continue; }
      await mkdir(dirname(from), { recursive: true });
      await move(to, from);
      restored.push(from);
    } catch (e) { failed.push({ path: from, reason: e.message }); }
  }
  return { restored, failed };
}

export async function dirSize(dir, { maxEntries = 200000 } = {}) {
  let bytes = 0, items = 0;
  const stack = [dir];
  while (stack.length && items < maxEntries) {
    const d = stack.pop();
    let names;
    try { names = await readdir(d); } catch { continue; }
    for (const n of names) {
      if (items >= maxEntries) break;
      items++;
      const p = join(d, n);
      try {
        const l = await lstat(p); // lstat: never follow symlinks, so loops can't recurse
        if (l.isDirectory()) stack.push(p);
        else if (!l.isSymbolicLink()) bytes += l.size;
      } catch { /* vanished */ }
    }
  }
  return { bytes, items };
}

export async function trashSummary(trashDir) {
  let names;
  try { names = await readdir(trashDir); } catch (e) { if (e.code === 'ENOENT') return { count: 0, bytes: 0 }; throw e; }
  let bytes = 0;
  for (const n of names) {
    const p = join(trashDir, n), l = await lstat(p).catch(() => null);
    if (!l) continue; // vanished
    bytes += l.isDirectory() ? (await dirSize(p)).bytes : l.isSymbolicLink() ? 0 : l.size;
  }
  return { count: names.length, bytes };
}

export async function emptyTrash(trashDir) {
  const s = await trashSummary(trashDir);
  if (s.count) for (const n of await readdir(trashDir)) await rm(join(trashDir, n), { recursive: true, force: true });
  return s;
}

export async function diskInfo(path) {
  const s = await statfs(path);
  return { total: s.blocks * s.bsize, free: s.bavail * s.bsize };
}
