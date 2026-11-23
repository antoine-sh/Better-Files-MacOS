import { splitExt, isDownloading } from './kinds.js';

// no node: imports here: the renderer imports this file for live validation
export function validateName(name) {
  if (!name || !name.trim()) return 'Name can\'t be empty';
  if (/[/:]/.test(name)) return 'Names can\'t contain / or :';
  if (name.startsWith('.')) return 'Names can\'t start with a dot';
  if (new TextEncoder().encode(name).length > 255) return 'Name is too long';
  return null;
}

export function extensionChange(oldName, newName) {
  const from = splitExt(oldName)[1], to = splitExt(newName)[1];
  return from.toLowerCase() === to.toLowerCase() ? null : { from, to };
}

export function planBatchRename(names, rule, existing) {
  const rows = names.map((from, i) => {
    if (isDownloading(from)) return { from, to: from, error: 'Still downloading' };
    const [base, ext] = splitExt(from);
    let nb = base;
    if (rule.type === 'replace') nb = rule.find ? base.split(rule.find).join(rule.with) : base;
    else if (rule.type === 'add') nb = rule.where === 'before' ? rule.text + base : base + rule.text;
    else if (rule.type === 'number') nb = `${rule.name} ${String((rule.start ?? 1) + i).padStart(2, '0')}`;
    const to = nb + ext;
    return { from, to, error: to === from ? null : validateName(to) };
  });
  const counts = new Map();
  for (const r of rows) counts.set(r.to, (counts.get(r.to) ?? 0) + 1);
  for (const r of rows) {
    if (r.error) continue;
    if (counts.get(r.to) > 1) r.error = 'Duplicate name';
    else if (r.to !== r.from && existing.has(r.to)) r.error = 'Already in this folder';
  }
  return rows;
}

export async function applyBatchRename(dir, plan) {
  const { join } = await import('node:path'); // dynamic: keeps this module renderer-safe
  const { renameItem, restore } = await import('./fsops.js');
  const moves = [];
  for (const { from, to, error } of plan) {
    if (error || from === to) continue;
    await renameItem(join(dir, from), to);
    moves.push({ from: join(dir, from), to: join(dir, to) });
  }
  return { renamed: moves.length, undo: () => restore(moves.reverse()) };
}
