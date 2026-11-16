import {
  S3Client,
  ListBucketsCommand,
  ListObjectsV2Command,
  GetObjectCommand,
} from '@aws-sdk/client-s3';
import { cachedCredentials } from './credential-cache.js';
import { openArchive, imageMimeType, type OpenArchive } from '../archive.js';
import type { S3Bucket, S3Object, S3Objects, S3FilePreview, ZipEntry, ZipEntryList, ZipEntryContent } from '../../domain/entities/index.js';

function createS3Client(profile: string, region: string): S3Client {
  return new S3Client({
    region,
    credentials: cachedCredentials(profile),
  });
}

export async function listBuckets(profile: string, region: string): Promise<S3Bucket[]> {
  const client = createS3Client(profile, region);
  const command = new ListBucketsCommand({});
  const response = await client.send(command);

  return (response.Buckets || []).map((bucket) => ({
    name: bucket.Name || '',
    creationDate: bucket.CreationDate?.toISOString(),
  }));
}

export async function listObjects(
  profile: string,
  region: string,
  bucket: string,
  prefix?: string
): Promise<S3Objects> {
  const client = createS3Client(profile, region);

  const command = new ListObjectsV2Command({
    Bucket: bucket,
    Prefix: prefix || '',
    Delimiter: '/',
    MaxKeys: 1000,
  });

  const response = await client.send(command);

  return {
    prefix: prefix || '',
    objects: (response.Contents || []).map((obj) => ({
      key: obj.Key || '',
      size: obj.Size || 0,
      lastModified: obj.LastModified?.toISOString(),
      storageClass: obj.StorageClass,
    })),
    commonPrefixes: (response.CommonPrefixes || []).map((cp) => cp.Prefix || ''),
    isTruncated: response.IsTruncated || false,
    nextContinuationToken: response.NextContinuationToken,
  };
}

const SEARCH_MAX_RESULTS = 500;
// A page-count cap (e.g. "stop after 20k keys") silently missed anything
// alphabetically past that point in a large bucket - a real bucket with
// hundreds of thousands of keys would never reach a file sorted near the
// end. A wall-clock budget instead scans as far as it can in the time
// given, regardless of how the bucket is laid out.
const SEARCH_TIME_BUDGET_MS = 20000; // stays under the Swift client's 30s request timeout

/**
 * Flat (no delimiter) recursive listing under `prefix`, filtered by
 * substring match on the full key - covers both "search this folder" (call
 * with the current prefix) and "search the whole bucket" (call with no
 * prefix) since S3 doesn't have real folders, just key paths.
 */
export async function searchObjects(
  profile: string,
  region: string,
  bucket: string,
  prefix: string | undefined,
  query: string
): Promise<S3Object[]> {
  const client = createS3Client(profile, region);
  const lowerQuery = query.toLowerCase();
  const results: S3Object[] = [];
  let continuationToken: string | undefined;
  const deadline = Date.now() + SEARCH_TIME_BUDGET_MS;

  do {
    const response = await client.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        Prefix: prefix || '',
        MaxKeys: 1000,
        ContinuationToken: continuationToken,
      })
    );

    for (const obj of response.Contents || []) {
      const key = obj.Key || '';
      if (key.toLowerCase().includes(lowerQuery)) {
        results.push({
          key,
          size: obj.Size || 0,
          lastModified: obj.LastModified?.toISOString(),
          storageClass: obj.StorageClass,
        });
        if (results.length >= SEARCH_MAX_RESULTS) return results;
      }
    }

    continuationToken = response.NextContinuationToken;
  } while (continuationToken && Date.now() < deadline);

  return results;
}

/**
 * Delimiter-scoped search: matches only against items directly inside
 * `prefix` (files, and subfolder names) rather than recursing into
 * subfolders - the "This Folder" counterpart to `searchObjects`'s whole-
 * bucket recursive search. Unlike the plain `listObjects` call the folder
 * view normally loads (capped at one 1000-key page), this paginates through
 * *every* page of the folder within the time budget, so a folder with more
 * than 1000 entries is actually searched in full instead of silently only
 * covering whatever page happened to load first.
 */
export async function searchFolderObjects(
  profile: string,
  region: string,
  bucket: string,
  prefix: string | undefined,
  query: string
): Promise<S3Objects> {
  const client = createS3Client(profile, region);
  const lowerQuery = query.toLowerCase();
  const matchedObjects: S3Object[] = [];
  const matchedPrefixes: string[] = [];
  let continuationToken: string | undefined;
  const deadline = Date.now() + SEARCH_TIME_BUDGET_MS;

  do {
    const response = await client.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        Prefix: prefix || '',
        Delimiter: '/',
        MaxKeys: 1000,
        ContinuationToken: continuationToken,
      })
    );

    for (const cp of response.CommonPrefixes || []) {
      const folderPrefix = cp.Prefix || '';
      const name = folderPrefix.replace(/\/$/, '').split('/').pop() || folderPrefix;
      if (name.toLowerCase().includes(lowerQuery)) {
        matchedPrefixes.push(folderPrefix);
      }
    }

    for (const obj of response.Contents || []) {
      const key = obj.Key || '';
      const name = key.split('/').pop() || key;
      if (name.toLowerCase().includes(lowerQuery)) {
        matchedObjects.push({
          key,
          size: obj.Size || 0,
          lastModified: obj.LastModified?.toISOString(),
          storageClass: obj.StorageClass,
        });
      }
    }

    continuationToken = response.NextContinuationToken;
  } while (continuationToken && Date.now() < deadline);

  return {
    prefix: prefix || '',
    objects: matchedObjects,
    commonPrefixes: matchedPrefixes,
    isTruncated: false,
    nextContinuationToken: undefined,
  };
}

const TEXT_CONTENT_TYPES = new Set([
  'text/plain',
  'text/html',
  'text/css',
  'text/csv',
  'text/xml',
  'application/json',
  'application/xml',
  'application/javascript',
  'application/x-yaml',
  'application/yaml',
]);

const MAX_PREVIEW_SIZE = 1024 * 1024; // 1MB

function isTextContentType(contentType: string): boolean {
  if (TEXT_CONTENT_TYPES.has(contentType)) return true;
  if (contentType.startsWith('text/')) return true;
  if (contentType.includes('json') || contentType.includes('xml')) return true;
  return false;
}

export async function getObject(
  profile: string,
  region: string,
  bucket: string,
  key: string
): Promise<S3FilePreview> {
  const client = createS3Client(profile, region);

  const command = new GetObjectCommand({
    Bucket: bucket,
    Key: key,
  });

  const response = await client.send(command);

  const contentType = response.ContentType || 'application/octet-stream';
  const size = response.ContentLength || 0;
  const isText = isTextContentType(contentType);
  let body: string | undefined;
  let isTruncated = false;

  if (isText && response.Body) {
    const bodyString = await response.Body.transformToString('utf-8');
    if (bodyString.length > MAX_PREVIEW_SIZE) {
      body = bodyString.slice(0, MAX_PREVIEW_SIZE);
      isTruncated = true;
    } else {
      body = bodyString;
    }
  }

  return {
    key,
    contentType,
    size,
    lastModified: response.LastModified?.toISOString(),
    body,
    isText,
    isTruncated,
  };
}

export async function getObjectBytes(
  profile: string,
  region: string,
  bucket: string,
  key: string
): Promise<{ bytes: Uint8Array; contentType: string }> {
  const client = createS3Client(profile, region);
  const response = await client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const bytes = await response.Body!.transformToByteArray();
  return { bytes, contentType: response.ContentType || 'application/octet-stream' };
}

/**
 * The archive found by descending through a chain of nested archive
 * entries (e.g. a .dat entry inside a .eff file that is itself a zip). An
 * empty pathChain is the outer archive at `key` itself. Any zip / gzip /
 * tar works at every level (see `openArchive`).
 */
async function resolveArchiveAtPath(
  profile: string,
  region: string,
  bucket: string,
  key: string,
  pathChain: string[]
): Promise<OpenArchive> {
  const { bytes } = await getObjectBytes(profile, region, bucket, key);
  let archive = await openArchive(bytes, key);
  for (const segment of pathChain) {
    archive = await openArchive(await archive.read(segment), segment);
  }
  return archive;
}

export async function listZipEntries(
  profile: string,
  region: string,
  bucket: string,
  key: string,
  pathChain: string[] = []
): Promise<ZipEntryList> {
  const archive = await resolveArchiveAtPath(profile, region, bucket, key, pathChain);
  const entries: ZipEntry[] = archive.entries.map((e) => ({ path: e.path, isDirectory: e.isDirectory }));
  entries.sort((a, b) => a.path.localeCompare(b.path));
  return { entries };
}

/** Raw bytes of one entry (images, downloads) - `pathChain` ends with the entry. */
export async function getZipEntryBytes(
  profile: string,
  region: string,
  bucket: string,
  key: string,
  pathChain: string[]
): Promise<{ bytes: Uint8Array; contentType: string }> {
  if (pathChain.length === 0) throw new Error('No entry path provided');
  const entryPath = pathChain[pathChain.length - 1];
  const archive = await resolveArchiveAtPath(profile, region, bucket, key, pathChain.slice(0, -1));
  return { bytes: await archive.read(entryPath), contentType: imageMimeType(entryPath) || 'application/octet-stream' };
}

const MAX_ZIP_ENTRY_PREVIEW_SIZE = 1024 * 1024; // 1MB

export async function getZipEntryContent(
  profile: string,
  region: string,
  bucket: string,
  key: string,
  pathChain: string[]
): Promise<ZipEntryContent> {
  if (pathChain.length === 0) {
    throw new Error('No entry path provided');
  }

  const entryPath = pathChain[pathChain.length - 1];
  const archive = await resolveArchiveAtPath(profile, region, bucket, key, pathChain.slice(0, -1));
  const content = Buffer.from(await archive.read(entryPath)).toString('utf8');
  const isTruncated = content.length > MAX_ZIP_ENTRY_PREVIEW_SIZE;

  return {
    path: entryPath,
    content: isTruncated ? content.slice(0, MAX_ZIP_ENTRY_PREVIEW_SIZE) : content,
    isTruncated,
  };
}
