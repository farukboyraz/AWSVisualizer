import { Router } from 'express';
import {
  listBuckets,
  listObjects,
  searchObjects,
  searchFolderObjects,
  getObject,
  getObjectBytes,
  listZipEntries,
  getZipEntryContent, getZipEntryBytes,
} from '../../infrastructure/aws/s3.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

function parsePathChain(raw: unknown): string[] {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw.map(String);
  return [String(raw)];
}

// GET /api/s3/buckets
router.get('/s3/buckets', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';

    const buckets = await listBuckets(profile, region);
    res.json(buckets);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/objects
router.get('/s3/objects', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const prefix = (req.query.prefix as string) || '';

    const objects = await listObjects(profile, region, bucket, prefix);
    res.json(objects);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/search - recursive key search, scoped by an optional prefix
router.get('/s3/search', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const prefix = req.query.prefix as string | undefined;
    const query = (req.query.query as string) || '';
    if (!query) {
      res.status(400).json({ error: 'query is required' });
      return;
    }

    const results = await searchObjects(profile, region, bucket, prefix, query);
    res.json(results);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/search-folder - delimiter-scoped search across every page of
// one folder (not just the first 1000-key page `listObjects` loads)
router.get('/s3/search-folder', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const prefix = req.query.prefix as string | undefined;
    const query = (req.query.query as string) || '';
    if (!query) {
      res.status(400).json({ error: 'query is required' });
      return;
    }

    const results = await searchFolderObjects(profile, region, bucket, prefix, query);
    res.json(results);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/object
router.get('/s3/object', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const key = (req.query.key as string) || '';

    const object = await getObject(profile, region, bucket, key);
    res.json(object);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/download
router.get('/s3/download', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const key = (req.query.key as string) || '';

    const { bytes, contentType } = await getObjectBytes(profile, region, bucket, key);
    const fileName = key.split('/').pop() || 'download';

    res.setHeader('Content-Type', contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${fileName.replace(/"/g, '')}"`);
    res.send(Buffer.from(bytes));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/zip-entries
router.get('/s3/zip-entries', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const key = (req.query.key as string) || '';
    const pathChain = parsePathChain(req.query.path);

    const result = await listZipEntries(profile, region, bucket, key, pathChain);
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/zip-entry
router.get('/s3/zip-entry', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const key = (req.query.key as string) || '';
    const pathChain = parsePathChain(req.query.path);

    const result = await getZipEntryContent(profile, region, bucket, key, pathChain);
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/s3/zip-entry-raw - one archive entry's bytes (image preview)
router.get('/s3/zip-entry-raw', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const bucket = (req.query.bucket as string) || '';
    const key = (req.query.key as string) || '';
    const pathChain = parsePathChain(req.query.path);

    const { bytes, contentType } = await getZipEntryBytes(profile, region, bucket, key, pathChain);
    res.setHeader('Content-Type', contentType);
    res.send(Buffer.from(bytes));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
