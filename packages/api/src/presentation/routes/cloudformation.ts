import { Router } from 'express';
import {
  listStacks,
  getStackDetail,
  getStackEvents,
  getStackResources,
  getStackTemplate,
  setTerminationProtection,
  deleteStack,
} from '../../infrastructure/aws/cloudformation.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

router.get('/cloudformation/stacks', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    res.json(await listStacks(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudformation/stack', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const result = await getStackDetail(profile, region, name);
    if (!result) {
      res.status(404).json({ error: 'Stack not found' });
      return;
    }
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudformation/stack/events', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const limit = req.query.limit ? Number(req.query.limit) : 100;
    res.json(await getStackEvents(profile, region, name, limit));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudformation/stack/resources', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    res.json(await getStackResources(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudformation/stack/template', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const templateBody = await getStackTemplate(profile, region, name);
    res.json({ templateBody });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/cloudformation/stack/termination-protection', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { stackName, enabled } = req.body || {};
    if (!stackName || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'stackName and enabled are required' });
      return;
    }
    const result = await setTerminationProtection(profile, region, stackName, enabled);
    if (!result) {
      res.status(404).json({ error: 'Stack not found' });
      return;
    }
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudformation/stack/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { stackName } = req.body || {};
    if (!stackName) {
      res.status(400).json({ error: 'stackName is required' });
      return;
    }
    await deleteStack(profile, region, stackName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
