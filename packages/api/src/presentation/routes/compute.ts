import { Router } from 'express';
import {
  listAutoScalingGroups,
  getAutoScalingGroupDetail,
  getAutoScalingGroupScaling,
  getAutoScalingGroupActivity,
  updateCapacity,
  setInstanceProtection,
  addAsgTag,
  removeAsgTag,
} from '../../infrastructure/aws/autoscaling.js';
import {
  BATCH_JOB_STATUSES,
  getBatchOverview,
  getJobQueue,
  getComputeEnvironment,
  getJobDefinition,
  listJobs,
  getJob,
  setJobQueueState,
  setComputeEnvironmentState,
  terminateJob,
  addBatchTag,
  removeBatchTag,
} from '../../infrastructure/aws/batch.js';
import {
  listLightsailInstances,
  getLightsailInstanceDetail,
  listLightsailDatabases,
  listLightsailContainerServices,
  runLightsailInstanceAction,
  addLightsailTag,
  removeLightsailTag,
  type LightsailInstanceAction,
} from '../../infrastructure/aws/lightsail.js';
import { listSarApplications, getSarApplicationDetail } from '../../infrastructure/aws/serverless-repo.js';
import { listOutposts, getOutpostDetail } from '../../infrastructure/aws/outposts.js';
import {
  listEdgeZones,
  getEdgeZoneGroup,
  setZoneGroupOptIn,
  listEnclaveInstances,
  type EdgeZoneType,
} from '../../infrastructure/aws/ec2-edge.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

function isNonNegativeInt(v: unknown): v is number {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0;
}

// ---- EC2 Auto Scaling ----

router.get('/autoscaling/groups', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listAutoScalingGroups(profile, region));
});

router.get('/autoscaling/group', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getAutoScalingGroupDetail(profile, region, name));
});

router.get('/autoscaling/group/scaling', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getAutoScalingGroupScaling(profile, region, name));
});

router.get('/autoscaling/group/activity', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getAutoScalingGroupActivity(profile, region, name));
});

router.put('/autoscaling/group/capacity', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, minSize, maxSize, desiredCapacity } = req.body || {};
  if (rejectMissing(res, { name })) return;
  if (![minSize, maxSize, desiredCapacity].every(isNonNegativeInt)) {
    res.status(400).json({ error: 'minSize, maxSize and desiredCapacity must be non-negative integers' });
    return;
  }
  if (minSize > desiredCapacity || desiredCapacity > maxSize) {
    res.status(400).json({ error: 'Capacity must satisfy min ≤ desired ≤ max' });
    return;
  }
  await respond(res, () => updateCapacity(profile, region, name, minSize, maxSize, desiredCapacity));
});

router.put('/autoscaling/group/protection', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, instanceIds, protectedFromScaleIn } = req.body || {};
  if (rejectMissing(res, { name })) return;
  if (!Array.isArray(instanceIds) || instanceIds.length === 0 || typeof protectedFromScaleIn !== 'boolean') {
    res.status(400).json({ error: 'instanceIds (non-empty) and protectedFromScaleIn are required' });
    return;
  }
  await respond(res, () => setInstanceProtection(profile, region, name, instanceIds, protectedFromScaleIn));
});

router.post('/autoscaling/group/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, key, value, propagateAtLaunch } = req.body || {};
  if (rejectMissing(res, { name, key })) return;
  await respond(res, () => addAsgTag(profile, region, name, key, value ?? '', propagateAtLaunch !== false));
});

router.post('/autoscaling/group/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, key } = req.body || {};
  if (rejectMissing(res, { name, key })) return;
  await respond(res, () => removeAsgTag(profile, region, name, key));
});

// ---- Batch ----

router.get('/batch/overview', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => getBatchOverview(profile, region));
});

router.get('/batch/job-queue', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getJobQueue(profile, region, name));
});

router.get('/batch/compute-environment', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getComputeEnvironment(profile, region, name));
});

router.get('/batch/job-definition', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => getJobDefinition(profile, region, arn));
});

router.get('/batch/jobs', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const queue = req.query.queue as string;
  const status = ((req.query.status as string) || 'RUNNING').toUpperCase();
  if (rejectMissing(res, { queue })) return;
  if (!(BATCH_JOB_STATUSES as readonly string[]).includes(status)) {
    res.status(400).json({ error: `status must be one of ${BATCH_JOB_STATUSES.join(', ')}` });
    return;
  }
  await respond(res, () => listJobs(profile, region, queue, status));
});

router.get('/batch/job', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const jobId = req.query.jobId as string;
  if (rejectMissing(res, { jobId })) return;
  await respond(res, () => getJob(profile, region, jobId));
});

router.put('/batch/job-queue/state', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, enabled } = req.body || {};
  if (rejectMissing(res, { name }) || typeof enabled !== 'boolean') {
    if (!res.headersSent) res.status(400).json({ error: 'enabled must be a boolean' });
    return;
  }
  await respond(res, () => setJobQueueState(profile, region, name, enabled));
});

router.put('/batch/compute-environment/state', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, enabled } = req.body || {};
  if (rejectMissing(res, { name }) || typeof enabled !== 'boolean') {
    if (!res.headersSent) res.status(400).json({ error: 'enabled must be a boolean' });
    return;
  }
  await respond(res, () => setComputeEnvironmentState(profile, region, name, enabled));
});

router.post('/batch/job/terminate', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { jobId, reason } = req.body || {};
  if (rejectMissing(res, { jobId })) return;
  await respond(res, () => terminateJob(profile, region, jobId, (reason as string) || 'Terminated from AWS Visualizer'));
});

router.post('/batch/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key, value } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => addBatchTag(profile, region, arn, key, value ?? ''));
});

router.post('/batch/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => removeBatchTag(profile, region, arn, key));
});

// ---- Lightsail ----

router.get('/lightsail/instances', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listLightsailInstances(profile, region));
});

router.get('/lightsail/instance', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getLightsailInstanceDetail(profile, region, name));
});

router.get('/lightsail/databases', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listLightsailDatabases(profile, region));
});

router.get('/lightsail/container-services', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listLightsailContainerServices(profile, region));
});

router.post('/lightsail/instance/action', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, action } = req.body || {};
  if (rejectMissing(res, { name, action })) return;
  if (!['start', 'stop', 'reboot'].includes(action)) {
    res.status(400).json({ error: 'action must be start, stop or reboot' });
    return;
  }
  await respond(res, () => runLightsailInstanceAction(profile, region, name, action as LightsailInstanceAction));
});

router.post('/lightsail/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { resourceName, key, value } = req.body || {};
  if (rejectMissing(res, { resourceName, key })) return;
  await respond(res, () => addLightsailTag(profile, region, resourceName, key, value ?? ''));
});

router.post('/lightsail/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { resourceName, key } = req.body || {};
  if (rejectMissing(res, { resourceName, key })) return;
  await respond(res, () => removeLightsailTag(profile, region, resourceName, key));
});

// ---- Serverless Application Repository ----

router.get('/serverlessrepo/applications', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listSarApplications(profile, region));
});

router.get('/serverlessrepo/application', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => getSarApplicationDetail(profile, region, id));
});

// ---- Outposts ----

router.get('/outposts', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listOutposts(profile, region));
});

router.get('/outposts/outpost', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => getOutpostDetail(profile, region, id));
});

// ---- Wavelength / Local Zones ----

function zoneType(raw: unknown): EdgeZoneType | undefined {
  return raw === 'wavelength-zone' || raw === 'local-zone' ? raw : undefined;
}

router.get('/edge-zones', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const type = zoneType(req.query.type);
  if (!type) {
    res.status(400).json({ error: 'type must be wavelength-zone or local-zone' });
    return;
  }
  await respond(res, () => listEdgeZones(profile, region, type));
});

router.get('/edge-zones/group', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const type = zoneType(req.query.type);
  const group = req.query.group as string;
  if (!type) {
    res.status(400).json({ error: 'type must be wavelength-zone or local-zone' });
    return;
  }
  if (rejectMissing(res, { group })) return;
  await respond(res, () => getEdgeZoneGroup(profile, region, type, group));
});

router.put('/edge-zones/group/opt-in', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { type: rawType, group, optedIn } = req.body || {};
  const type = zoneType(rawType);
  if (!type || typeof optedIn !== 'boolean') {
    res.status(400).json({ error: 'type (wavelength-zone | local-zone) and optedIn (boolean) are required' });
    return;
  }
  if (rejectMissing(res, { group })) return;
  await respond(res, () => setZoneGroupOptIn(profile, region, type, group, optedIn));
});

// ---- Nitro Enclaves ----

router.get('/nitro-enclaves/instances', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listEnclaveInstances(profile, region));
});

export default router;
