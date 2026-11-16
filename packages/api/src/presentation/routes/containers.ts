import { Router } from 'express';
import {
  listEksClusters,
  getEksCluster,
  getEksCompute,
  getEksAddons,
  getEksAccessEntries,
  getEksUpdates,
  updateNodegroupScaling,
  addEksTag,
  removeEksTag,
} from '../../infrastructure/aws/eks.js';
import { getFargateOverview } from '../../infrastructure/aws/fargate.js';
import {
  listAppRunnerServices,
  getAppRunnerService,
  getAppRunnerActivity,
  runAppRunnerAction,
  addAppRunnerTag,
  removeAppRunnerTag,
  type AppRunnerAction,
} from '../../infrastructure/aws/apprunner.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

const isCount = (v: unknown): v is number => typeof v === 'number' && Number.isInteger(v) && v >= 0;

// ---- EKS ----

router.get('/eks/clusters', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listEksClusters(profile, region));
});

for (const [path, fn] of [
  ['/eks/cluster', getEksCluster],
  ['/eks/cluster/compute', getEksCompute],
  ['/eks/cluster/addons', getEksAddons],
  ['/eks/cluster/access', getEksAccessEntries],
  ['/eks/cluster/updates', getEksUpdates],
] as const) {
  router.get(path, async (req, res) => {
    const { profile, region } = profileRegion(req);
    const name = req.query.name as string;
    if (rejectMissing(res, { name })) return;
    await respond(res, () => (fn as (p: string, r: string, n: string) => Promise<unknown>)(profile, region, name));
  });
}

router.put('/eks/nodegroup/scaling', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { cluster, nodegroup, minSize, maxSize, desiredSize } = req.body || {};
  if (rejectMissing(res, { cluster, nodegroup })) return;
  if (![minSize, maxSize, desiredSize].every(isCount) || maxSize < 1) {
    res.status(400).json({ error: 'minSize, desiredSize (≥ 0) and maxSize (≥ 1) must be integers' });
    return;
  }
  if (minSize > desiredSize || desiredSize > maxSize) {
    res.status(400).json({ error: 'Scaling must satisfy min ≤ desired ≤ max' });
    return;
  }
  await respond(res, () => updateNodegroupScaling(profile, region, cluster, nodegroup, minSize, maxSize, desiredSize));
});

router.post('/eks/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key, value } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => addEksTag(profile, region, arn, key, value ?? ''));
});

router.post('/eks/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => removeEksTag(profile, region, arn, key));
});

// ---- Fargate ----

router.get('/fargate/overview', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => getFargateOverview(profile, region));
});

// ---- App Runner ----

router.get('/apprunner/services', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listAppRunnerServices(profile, region));
});

router.get('/apprunner/service', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => getAppRunnerService(profile, region, arn));
});

router.get('/apprunner/service/activity', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => getAppRunnerActivity(profile, region, arn));
});

router.post('/apprunner/service/action', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, action } = req.body || {};
  if (rejectMissing(res, { arn, action })) return;
  if (!['pause', 'resume', 'deploy'].includes(action)) {
    res.status(400).json({ error: 'action must be pause, resume or deploy' });
    return;
  }
  await respond(res, () => runAppRunnerAction(profile, region, arn, action as AppRunnerAction));
});

router.post('/apprunner/service/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key, value } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => addAppRunnerTag(profile, region, arn, key, value ?? ''));
});

router.post('/apprunner/service/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => removeAppRunnerTag(profile, region, arn, key));
});

export default router;
