import { Router } from 'express';
import {
  listInstances,
  getInstanceDetail,
  setInstanceState,
  setInstanceType,
  setTerminationProtection,
  setMonitoring,
  addInstanceTag,
  removeInstanceTag,
  listKeyPairs,
  launchInstance,
  type Ec2InstanceStateAction,
} from '../../infrastructure/aws/ec2.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/ec2/instances
router.get('/ec2/instances', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listInstances(profile, region));
});

router.get('/ec2/instance', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const instanceId = (req.query.instanceId as string) || '';
    res.json(await getInstanceDetail(profile, region, instanceId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/ec2/instance/state', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { instanceId, action } = req.body || {};
    const validActions: Ec2InstanceStateAction[] = ['start', 'stop', 'reboot', 'terminate'];
    if (!instanceId || !validActions.includes(action)) {
      res.status(400).json({ error: 'instanceId and a valid action (start, stop, reboot, terminate) are required' });
      return;
    }
    await setInstanceState(profile, region, instanceId, action);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/ec2/instance/type', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { instanceId, instanceType } = req.body || {};
    if (!instanceId || !instanceType) {
      res.status(400).json({ error: 'instanceId and instanceType are required' });
      return;
    }
    res.json(await setInstanceType(profile, region, instanceId, instanceType));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/ec2/instance/termination-protection', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { instanceId, enabled } = req.body || {};
    if (!instanceId || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'instanceId and enabled are required' });
      return;
    }
    res.json(await setTerminationProtection(profile, region, instanceId, enabled));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/ec2/instance/monitoring', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { instanceId, enabled } = req.body || {};
    if (!instanceId || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'instanceId and enabled are required' });
      return;
    }
    res.json(await setMonitoring(profile, region, instanceId, enabled));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/ec2/instance/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { instanceId, key, value } = req.body || {};
    if (!instanceId || !key) {
      res.status(400).json({ error: 'instanceId and key are required' });
      return;
    }
    res.json(await addInstanceTag(profile, region, instanceId, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/ec2/instance/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { instanceId, key } = req.body || {};
    if (!instanceId || !key) {
      res.status(400).json({ error: 'instanceId and key are required' });
      return;
    }
    res.json(await removeInstanceTag(profile, region, instanceId, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/ec2/key-pairs', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    res.json(await listKeyPairs(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/ec2/instances/launch', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { imageId, instanceType, keyName, securityGroupIds, subnetId, name } = req.body || {};
    if (!imageId || !instanceType) {
      res.status(400).json({ error: 'imageId and instanceType are required' });
      return;
    }
    res.json(
      await launchInstance(profile, region, {
        imageId,
        instanceType,
        keyName: keyName || undefined,
        securityGroupIds: Array.isArray(securityGroupIds) ? securityGroupIds : undefined,
        subnetId: subnetId || undefined,
        name: name || undefined,
      })
    );
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
