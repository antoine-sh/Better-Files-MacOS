export const KINDS = ['PDFs', 'Images', 'Screenshots', 'Videos', 'Installers', 'Archives', 'Audio', 'Documents', 'Other'];

const COMPOUND = ['.tar.gz', '.tar.bz2', '.tar.xz'];
const BY_EXT = {
  PDFs: ['pdf'],
  Images: ['png', 'jpg', 'jpeg', 'gif', 'heic', 'webp', 'tiff', 'bmp', 'svg'],
  Videos: ['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'],
  Installers: ['dmg', 'pkg', 'exe', 'msi', 'deb', 'appimage'],
  Archives: ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz'],
  Audio: ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'aiff'],
  Documents: ['doc', 'docx', 'txt', 'md', 'rtf', 'pages', 'xls', 'xlsx', 'numbers', 'ppt', 'pptx', 'key', 'csv', 'odt'],
};
const EXT_KIND = new Map(Object.entries(BY_EXT).flatMap(([k, es]) => es.map((e) => [e, k])));

export function splitExt(name) {
  const lower = name.toLowerCase();
  for (const c of COMPOUND) if (lower.endsWith(c) && name.length > c.length) return [name.slice(0, -c.length), name.slice(-c.length)];
  const i = name.lastIndexOf('.');
  if (i <= 0 || i === name.length - 1) return [name, ''];
  return [name.slice(0, i), name.slice(i)];
}

export function kindOf(name) {
  if (/^Screen ?[Ss]hot .*\.(png|jpe?g)$/.test(name)) return 'Screenshots';
  return EXT_KIND.get(splitExt(name)[1].split('.').pop().toLowerCase()) ?? 'Other';
}

export const isDownloading = (name) => /\.(crdownload|download|part|opdownload)$/i.test(name);

export function formatBytes(n) {
  if (n < 1000) return `${n} bytes`;
  const u = ['KB', 'MB', 'GB', 'TB'];
  let i = -1;
  do { n /= 1000; i++; } while (n >= 1000 && i < u.length - 1);
  return `${n.toFixed(1)} ${u[i]}`;
}
