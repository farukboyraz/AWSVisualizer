import { Router } from 'express';
import { listTables, describeTable, scanTable, searchTable, putItem, deleteItem, getItemTyped, putItemTyped, getTableAttributeNames } from '../../infrastructure/aws/dynamodb.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';
import {
  getTableDetail,
  setDeletionProtection,
  setPointInTimeRecovery,
  setTimeToLive,
  addTableTag,
  removeTableTag,
  listBackups,
  createBackup,
  deleteBackup,
  getTableMetrics,
  queryTable,
  executePartiQL,
  createTable,
  deleteTable,
} from '../../infrastructure/aws/dynamodb-table.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

// GET /api/dynamodb/tables
router.get('/dynamodb/tables', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';

    const tables = await listTables(profile, region);
    res.json(tables);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/dynamodb/table/:name/attributes - every attribute name for the Filter Builder (sparse ones too)
router.get('/dynamodb/table/:name/attributes', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => getTableAttributeNames(profile, region, req.params.name));
});

// GET /api/dynamodb/table/:name
router.get('/dynamodb/table/:name', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.params;

    const table = await describeTable(profile, region, name);
    res.json(table);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/dynamodb/scan/:name
router.get('/dynamodb/scan/:name', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const limit = parseInt((req.query.limit as string) || '25', 10);
    const startKeyStr = req.query.startKey as string | undefined;
    const startKey = startKeyStr ? JSON.parse(startKeyStr) : undefined;
    const { name } = req.params;

    const result = await scanTable(profile, region, name, limit, startKey);
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/dynamodb/search/:name - whole-table Filter Builder search
// Body: { conditions: DdbFilterCondition[], maxResults?: number, cursor?: string }
router.post('/dynamodb/search/:name', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.params;
    const { conditions, maxResults, cursor } = req.body || {};
    if (!Array.isArray(conditions) || conditions.length === 0) {
      res.status(400).json({ error: 'conditions must be a non-empty list' });
      return;
    }
    const limit = Math.min(Math.max(parseInt(String(maxResults ?? 100), 10) || 100, 1), 500);
    res.json(await searchTable(profile, region, name, conditions, limit, typeof cursor === 'string' && cursor ? cursor : undefined));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/dynamodb/item/:name/typed/get - one item as typed DynamoDB JSON
router.post('/dynamodb/item/:name/typed/get', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { key } = req.body || {};
    if (!key || typeof key !== 'object') {
      res.status(400).json({ error: 'key is required' });
      return;
    }
    res.json(await getItemTyped(profile, region, req.params.name, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/dynamodb/item/:name/typed - create or overwrite an item from typed DynamoDB JSON
router.post('/dynamodb/item/:name/typed', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    await putItemTyped(profile, region, req.params.name, (req.body || {}).item);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/dynamodb/item/:name - create or overwrite an item (PutItem)
router.post('/dynamodb/item/:name', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.params;
    const { item } = req.body || {};
    if (!item || typeof item !== 'object') {
      res.status(400).json({ error: 'item is required' });
      return;
    }
    await putItem(profile, region, name, item);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/dynamodb/item/:name/delete
router.post('/dynamodb/item/:name/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.params;
    const { key } = req.body || {};
    if (!key || typeof key !== 'object') {
      res.status(400).json({ error: 'key is required' });
      return;
    }
    await deleteItem(profile, region, name, key);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// ---- Table administration ----

router.get('/dynamodb/table/:name/detail', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => getTableDetail(profile, region, req.params.name));
});

router.put('/dynamodb/table/:name/deletion-protection', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { enabled } = req.body || {};
  if (rejectMissing(res, { enabled })) return;
  await respond(res, () => setDeletionProtection(profile, region, req.params.name, Boolean(enabled)));
});

router.put('/dynamodb/table/:name/pitr', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { enabled } = req.body || {};
  if (rejectMissing(res, { enabled })) return;
  await respond(res, () => setPointInTimeRecovery(profile, region, req.params.name, Boolean(enabled)));
});

router.put('/dynamodb/table/:name/ttl', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { attributeName, enabled } = req.body || {};
  if (rejectMissing(res, { attributeName, enabled })) return;
  await respond(res, () => setTimeToLive(profile, region, req.params.name, attributeName, Boolean(enabled)));
});

router.post('/dynamodb/table/:name/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key, value } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => addTableTag(profile, region, req.params.name, arn, key, value || ''));
});

router.post('/dynamodb/table/:name/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => removeTableTag(profile, region, req.params.name, arn, key));
});

router.get('/dynamodb/table/:name/backups', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listBackups(profile, region, req.params.name));
});

router.post('/dynamodb/table/:name/backups', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { backupName } = req.body || {};
  if (rejectMissing(res, { backupName })) return;
  await respond(res, () => createBackup(profile, region, req.params.name, backupName));
});

router.post('/dynamodb/backups/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { backupArn } = req.body || {};
  if (rejectMissing(res, { backupArn })) return;
  await respond(res, () => deleteBackup(profile, region, backupArn));
});

router.get('/dynamodb/table/:name/metrics', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => getTableMetrics(profile, region, req.params.name));
});

router.post('/dynamodb/table/:name/query', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => queryTable(profile, region, req.params.name, req.body || {}));
});

router.post('/dynamodb/partiql', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { statement, nextToken, limit } = req.body || {};
  if (rejectMissing(res, { statement })) return;
  const rows = Math.min(Math.max(parseInt(String(limit ?? 1000), 10) || 1000, 1), 1000);
  await respond(res, () => executePartiQL(profile, region, statement, nextToken, rows));
});

router.post('/dynamodb/tables', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { tableName, partitionKey, sortKey } = req.body || {};
  if (rejectMissing(res, { tableName, partitionKey })) return;
  await respond(res, () => createTable(profile, region, { tableName, partitionKey, sortKey }));
});

router.post('/dynamodb/table/:name/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => deleteTable(profile, region, req.params.name));
});

export default router;
