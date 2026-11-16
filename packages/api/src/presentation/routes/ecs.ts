import { Router } from 'express';
import {
  listClusters,
  listServices,
  getServiceDetail,
  listServiceTasks,
  getTaskDefinition,
  updateDesiredCount,
  forceNewDeployment,
  stopTask,
  addServiceTag,
  removeServiceTag,
} from '../../infrastructure/aws/ecs.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

// GET /api/ecs/clusters
router.get('/ecs/clusters', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listClusters(profile, region));
});

router.get('/ecs/services', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const cluster = req.query.cluster as string;
  if (rejectMissing(res, { cluster })) return;
  await respond(res, () => listServices(profile, region, cluster));
});

router.get('/ecs/service', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const cluster = req.query.cluster as string;
  const service = req.query.service as string;
  if (rejectMissing(res, { cluster, service })) return;
  await respond(res, () => getServiceDetail(profile, region, cluster, service));
});

router.get('/ecs/service/tasks', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const cluster = req.query.cluster as string;
  const service = req.query.service as string;
  const desiredStatus = req.query.desiredStatus === 'STOPPED' ? 'STOPPED' : 'RUNNING';
  if (rejectMissing(res, { cluster, service })) return;
  await respond(res, () => listServiceTasks(profile, region, cluster, service, desiredStatus));
});

router.get('/ecs/task-definition', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const taskDefinition = req.query.taskDefinition as string;
  if (rejectMissing(res, { taskDefinition })) return;
  await respond(res, () => getTaskDefinition(profile, region, taskDefinition));
});

router.put('/ecs/service/desired-count', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { cluster, service, desiredCount } = req.body || {};
  if (rejectMissing(res, { cluster, service, desiredCount })) return;
  if (!Number.isInteger(desiredCount) || desiredCount < 0) {
    res.status(400).json({ error: 'desiredCount must be a non-negative integer' });
    return;
  }
  await respond(res, () => updateDesiredCount(profile, region, cluster, service, desiredCount));
});

router.post('/ecs/service/force-deployment', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { cluster, service } = req.body || {};
  if (rejectMissing(res, { cluster, service })) return;
  await respond(res, () => forceNewDeployment(profile, region, cluster, service));
});

router.post('/ecs/task/stop', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { cluster, task, reason } = req.body || {};
  if (rejectMissing(res, { cluster, task })) return;
  await respond(res, () => stopTask(profile, region, cluster, task, reason));
});

router.post('/ecs/service/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { cluster, service, serviceArn, key, value } = req.body || {};
  if (rejectMissing(res, { cluster, service, serviceArn, key })) return;
  await respond(res, () => addServiceTag(profile, region, cluster, service, serviceArn, key, value || ''));
});

router.post('/ecs/service/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { cluster, service, serviceArn, key } = req.body || {};
  if (rejectMissing(res, { cluster, service, serviceArn, key })) return;
  await respond(res, () => removeServiceTag(profile, region, cluster, service, serviceArn, key));
});

export default router;
