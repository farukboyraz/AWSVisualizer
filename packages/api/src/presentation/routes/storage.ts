import { Router, type Request, type Response } from 'express';
import { listEfsFileSystems, getEfsFileSystem, getEfsFileSystemExtras, addEfsTag, removeEfsTag } from '../../infrastructure/aws/efs.js';
import { listFsxFileSystems, getFsxFileSystem, getFsxFileSystemExtras, addFsxTag, removeFsxTag } from '../../infrastructure/aws/fsx.js';
import { listEbsVolumes, listEbsSnapshots, getEbsVolume, createEbsSnapshot, addEbsTag, removeEbsTag } from '../../infrastructure/aws/ebs.js';
import {
  listGlacierVaults,
  getGlacierVault,
  listGlacierJobs,
  requestGlacierInventory,
  getGlacierInventory,
  addGlacierTag,
  removeGlacierTag,
} from '../../infrastructure/aws/glacier.js';
import {
  listStorageGateways,
  getStorageGateway,
  getStorageGatewayStorage,
  addStorageGatewayTag,
  removeStorageGatewayTag,
} from '../../infrastructure/aws/storage-gateway.js';
import {
  getBackupOverview,
  getBackupPlan,
  getBackupVault,
  listBackupJobs,
  addBackupTag,
  removeBackupTag,
  type BackupJobKind,
} from '../../infrastructure/aws/backup.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

type Fetch = (profile: string, region: string, value: string) => Promise<unknown>;

/** GET route taking one required query parameter. */
function getBy(path: string, param: string, fn: Fetch) {
  router.get(path, async (req: Request, res: Response) => {
    const { profile, region } = profileRegion(req);
    const value = req.query[param] as string;
    if (rejectMissing(res, { [param]: value })) return;
    await respond(res, () => fn(profile, region, value));
  });
}

/** POST add/remove tag routes; `idField` names the body field identifying the resource. */
function tagRoutes(
  path: string,
  idField: string,
  add: (p: string, r: string, id: string, k: string, v: string) => Promise<unknown>,
  remove: (p: string, r: string, id: string, k: string) => Promise<unknown>,
) {
  router.post(path, async (req, res) => {
    const { profile, region } = profileRegion(req);
    const body = req.body || {};
    if (rejectMissing(res, { [idField]: body[idField], key: body.key })) return;
    await respond(res, () => add(profile, region, body[idField], body.key, body.value ?? ''));
  });
  router.post(`${path}/remove`, async (req, res) => {
    const { profile, region } = profileRegion(req);
    const body = req.body || {};
    if (rejectMissing(res, { [idField]: body[idField], key: body.key })) return;
    await respond(res, () => remove(profile, region, body[idField], body.key));
  });
}

// ---- EFS ----

router.get('/efs/file-systems', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listEfsFileSystems(profile, region));
});
getBy('/efs/file-system', 'id', getEfsFileSystem);
getBy('/efs/file-system/extras', 'id', getEfsFileSystemExtras);
tagRoutes('/efs/tags', 'id', addEfsTag, removeEfsTag);

// ---- FSx ----

router.get('/fsx/file-systems', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listFsxFileSystems(profile, region));
});
getBy('/fsx/file-system', 'id', getFsxFileSystem);
router.get('/fsx/file-system/extras', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  const type = (req.query.type as string) || '';
  if (rejectMissing(res, { id })) return;
  await respond(res, () => getFsxFileSystemExtras(profile, region, id, type));
});
router.post('/fsx/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, arn, key, value } = req.body || {};
  if (rejectMissing(res, { id, arn, key })) return;
  await respond(res, () => addFsxTag(profile, region, id, arn, key, value ?? ''));
});
router.post('/fsx/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, arn, key } = req.body || {};
  if (rejectMissing(res, { id, arn, key })) return;
  await respond(res, () => removeFsxTag(profile, region, id, arn, key));
});

// ---- EBS ----

router.get('/ebs/volumes', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listEbsVolumes(profile, region));
});
router.get('/ebs/snapshots', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listEbsSnapshots(profile, region));
});
getBy('/ebs/volume', 'id', getEbsVolume);
router.post('/ebs/volume/snapshot', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, description } = req.body || {};
  if (rejectMissing(res, { id })) return;
  if (description !== undefined && (typeof description !== 'string' || description.length > 255)) {
    res.status(400).json({ error: 'description must be a string of at most 255 characters' });
    return;
  }
  await respond(res, () => createEbsSnapshot(profile, region, id, description ?? ''));
});
tagRoutes('/ebs/tags', 'id', addEbsTag, removeEbsTag);

// ---- S3 Glacier ----

router.get('/glacier/vaults', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listGlacierVaults(profile, region));
});
getBy('/glacier/vault', 'name', getGlacierVault);
getBy('/glacier/vault/jobs', 'name', listGlacierJobs);
router.post('/glacier/vault/inventory', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name } = req.body || {};
  if (rejectMissing(res, { name })) return;
  await respond(res, () => requestGlacierInventory(profile, region, name));
});
router.get('/glacier/vault/inventory', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  const jobId = req.query.jobId as string;
  if (rejectMissing(res, { name, jobId })) return;
  await respond(res, () => getGlacierInventory(profile, region, name, jobId));
});
tagRoutes('/glacier/tags', 'name', addGlacierTag, removeGlacierTag);

// ---- Storage Gateway ----

router.get('/storagegateway/gateways', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listStorageGateways(profile, region));
});
getBy('/storagegateway/gateway', 'arn', getStorageGateway);
getBy('/storagegateway/gateway/storage', 'arn', getStorageGatewayStorage);
tagRoutes('/storagegateway/tags', 'arn', addStorageGatewayTag, removeStorageGatewayTag);

// ---- AWS Backup ----

router.get('/backup/overview', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => getBackupOverview(profile, region));
});
getBy('/backup/plan', 'id', getBackupPlan);
getBy('/backup/vault', 'name', getBackupVault);
router.get('/backup/jobs', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const kind = (req.query.kind as string) || 'backup';
  if (!['backup', 'restore', 'copy'].includes(kind)) {
    res.status(400).json({ error: 'kind must be backup, restore or copy' });
    return;
  }
  await respond(res, () => listBackupJobs(profile, region, kind as BackupJobKind));
});
tagRoutes('/backup/tags', 'arn', addBackupTag, removeBackupTag);

export default router;
