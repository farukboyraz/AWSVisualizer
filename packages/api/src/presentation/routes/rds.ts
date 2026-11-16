import { Router } from 'express';
import {
  listRdsInstances,
  getInstanceDetail,
  listInstanceEvents,
  listLogFiles,
  getLogTail,
  listSnapshots,
  createSnapshot,
  setInstanceState,
  modifyInstance,
  addInstanceTag,
  removeInstanceTag,
  getInstanceMetrics,
} from '../../infrastructure/aws/rds.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

// GET /api/rds/instances
router.get('/rds/instances', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listRdsInstances(profile, region));
});

router.get('/rds/instance', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => getInstanceDetail(profile, region, id));
});

router.get('/rds/instance/events', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => listInstanceEvents(profile, region, id));
});

router.get('/rds/instance/logs', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => listLogFiles(profile, region, id));
});

router.get('/rds/instance/log', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  const file = req.query.file as string;
  if (rejectMissing(res, { id, file })) return;
  await respond(res, () => getLogTail(profile, region, id, file));
});

router.get('/rds/instance/snapshots', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => listSnapshots(profile, region, id));
});

router.get('/rds/instance/metrics', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => getInstanceMetrics(profile, region, id));
});

router.post('/rds/instance/snapshots', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, snapshotId } = req.body || {};
  if (rejectMissing(res, { id, snapshotId })) return;
  await respond(res, () => createSnapshot(profile, region, id, snapshotId));
});

router.post('/rds/instance/state', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, action } = req.body || {};
  if (rejectMissing(res, { id, action })) return;
  if (!['start', 'stop', 'reboot'].includes(action)) {
    res.status(400).json({ error: 'action must be start, stop or reboot' });
    return;
  }
  await respond(res, () => setInstanceState(profile, region, id, action));
});

router.put('/rds/instance/modify', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, deletionProtection, backupRetentionPeriod } = req.body || {};
  if (rejectMissing(res, { id })) return;
  if (backupRetentionPeriod !== undefined && (!Number.isInteger(backupRetentionPeriod) || backupRetentionPeriod < 1 || backupRetentionPeriod > 35)) {
    // 0 disables automated backups, which RDS only applies with an outage -
    // deliberately not offered from here.
    res.status(400).json({ error: 'backupRetentionPeriod must be between 1 and 35' });
    return;
  }
  await respond(res, () => modifyInstance(profile, region, id, { deletionProtection, backupRetentionPeriod }));
});

router.post('/rds/instance/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, arn, key, value } = req.body || {};
  if (rejectMissing(res, { id, arn, key })) return;
  await respond(res, () => addInstanceTag(profile, region, id, arn, key, value || ''));
});

router.post('/rds/instance/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { id, arn, key } = req.body || {};
  if (rejectMissing(res, { id, arn, key })) return;
  await respond(res, () => removeInstanceTag(profile, region, id, arn, key));
});

export default router;
