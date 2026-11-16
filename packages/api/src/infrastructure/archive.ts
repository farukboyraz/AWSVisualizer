import JSZip from 'jszip';
import { gunzipSync } from 'node:zlib';

/**
 * Archives the S3 browser can open like a folder. Detected from the bytes
 * (magic numbers), not the name, so an .eff / .dat / .jar / .nupkg… that is
 * really a zip opens, and a .dat that isn't one reports "not an archive"
 * instead of failing oddly:
 * - **zip** and everything built on it (.zip .eff .jar .war .ear .apk .aar
 *   .nupkg .vsix .whl .ipa .epub, Office documents…)
 * - **gzip** (.gz) - a gzipped tar (.tar.gz / .tgz) lists the tar's files,
 *   any other .gz shows its single decompressed file
 * - **tar** (ustar, GNU long names, pax `path=`)
 */
export interface ArchiveEntryInfo {
  path: string;
  isDirectory: boolean;
}

export interface OpenArchive {
  kind: 'zip' | 'tar' | 'gzip';
  entries: ArchiveEntryInfo[];
  read(path: string): Promise<Uint8Array>;
}

/** Decompressed .gz larger than this is refused (zip bombs). */
const MAX_GUNZIP_BYTES = 512 * 1024 * 1024;

export function notAnArchive(name: string): Error {
  return Object.assign(new Error(`${name} is not an archive this viewer can open (zip, gzip or tar)`), {
    name: 'ValidationException',
    $metadata: { httpStatusCode: 400 },
  });
}

const isZip = (b: Uint8Array) => b.length >= 4 && b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05 || b[2] === 0x07);
const isGzip = (b: Uint8Array) => b.length >= 2 && b[0] === 0x1f && b[1] === 0x8b;
const isTar = (b: Uint8Array) => b.length >= 262 && Buffer.from(b.subarray(257, 262)).toString('latin1') === 'ustar';

export async function openArchive(bytes: Uint8Array, name: string): Promise<OpenArchive> {
  if (isZip(bytes)) {
    const zip = await JSZip.loadAsync(bytes);
    const entries: ArchiveEntryInfo[] = [];
    zip.forEach((path, file) => entries.push({ path, isDirectory: file.dir }));
    return {
      kind: 'zip',
      entries,
      read: async (path) => {
        const file = zip.file(path);
        if (!file) throw entryNotFound(path);
        return file.async('uint8array');
      },
    };
  }
  if (isGzip(bytes)) {
    const inner = new Uint8Array(gunzipSync(bytes, { maxOutputLength: MAX_GUNZIP_BYTES }));
    if (isTar(inner)) return tarArchive(inner);
    const innerName = (name.split('/').pop() || 'file').replace(/\.t?gz$/i, (m) => (m.toLowerCase() === '.tgz' ? '.tar' : '')) || 'file';
    return {
      kind: 'gzip',
      entries: [{ path: innerName, isDirectory: false }],
      read: async (path) => {
        if (path !== innerName) throw entryNotFound(path);
        return inner;
      },
    };
  }
  if (isTar(bytes)) return tarArchive(bytes);
  throw notAnArchive(name);
}

function entryNotFound(path: string): Error {
  return Object.assign(new Error(`Entry not found in archive: ${path}`), { name: 'NotFound', $metadata: { httpStatusCode: 404 } });
}

function tarString(b: Uint8Array, start: number, length: number): string {
  const slice = b.subarray(start, start + length);
  const end = slice.indexOf(0);
  return Buffer.from(end === -1 ? slice : slice.subarray(0, end)).toString('utf8');
}

function tarArchive(b: Uint8Array): OpenArchive {
  const files = new Map<string, Uint8Array>();
  const entries: ArchiveEntryInfo[] = [];
  let offset = 0;
  let longName: string | undefined;
  while (offset + 512 <= b.length) {
    const header = b.subarray(offset, offset + 512);
    if (header.every((x) => x === 0)) break;
    const size = parseInt(tarString(header, 124, 12).trim() || '0', 8) || 0;
    const type = String.fromCharCode(header[156] || 48);
    const prefix = tarString(header, 345, 155);
    let path = longName ?? (prefix ? `${prefix}/${tarString(header, 0, 100)}` : tarString(header, 0, 100));
    longName = undefined;
    const dataStart = offset + 512;
    const data = b.subarray(dataStart, dataStart + size);
    offset = dataStart + Math.ceil(size / 512) * 512;

    if (type === 'L') {
      longName = tarString(data, 0, data.length);
      continue;
    }
    if (type === 'x') {
      const match = /\d+ path=([^\n]*)\n/.exec(Buffer.from(data).toString('utf8'));
      if (match) longName = match[1];
      continue;
    }
    if (type === 'g') continue;
    path = path.replace(/^\.\//, '');
    if (!path) continue;
    if (type === '5') {
      entries.push({ path: path.endsWith('/') ? path : `${path}/`, isDirectory: true });
    } else if (type === '0' || type === '\0' || type === '7') {
      entries.push({ path, isDirectory: false });
      files.set(path, data);
    }
  }
  return {
    kind: 'tar',
    entries,
    read: async (path) => {
      const data = files.get(path);
      if (!data) throw entryNotFound(path);
      return data;
    },
  };
}

const IMAGE_TYPES: Record<string, string> = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp',
  bmp: 'image/bmp', tif: 'image/tiff', tiff: 'image/tiff', heic: 'image/heic', heif: 'image/heif',
  ico: 'image/x-icon', icns: 'image/icns',
};

/** `image/png` etc. for an image file name, otherwise undefined. */
export function imageMimeType(name: string): string | undefined {
  const ext = name.split('.').pop()?.toLowerCase() || '';
  return IMAGE_TYPES[ext];
}
