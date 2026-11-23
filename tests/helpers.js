import { mkdtemp, mkdir, writeFile, rm, utimes } from 'node:fs/promises';
import { tmpdir as osTmp } from 'node:os';
import { join, dirname } from 'node:path';
import { after } from 'node:test';

export async function tmpdir() {
  const d = await mkdtemp(join(osTmp(), 'fileos-'));
  after(() => rm(d, { recursive: true, force: true }));
  return d;
}

export async function touch(dir, rel, content = 'x', mtimeMs) {
  const p = join(dir, rel);
  await mkdir(dirname(p), { recursive: true });
  await writeFile(p, content);
  if (mtimeMs != null) await utimes(p, mtimeMs / 1000, mtimeMs / 1000);
  return p;
}
