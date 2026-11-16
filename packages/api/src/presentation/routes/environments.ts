import { Router } from 'express';
import {
  getEnvironments,
  getEvents,
  getEnvironmentDetail,
  restartAppServer,
  rebuildEnvironment,
  terminateEnvironment,
  swapEnvironmentCnames,
  setEnvironmentVariable,
  removeEnvironmentVariable,
  addEnvironmentTag,
  removeEnvironmentTag,
  cloneEnvironment,
  getEnvironmentHealth,
  getEnvironmentResources,
  getEnvironmentConfiguration,
  listApplicationVersions,
  deployApplicationVersion,
  fetchEnvironmentLogs,
  getManagedUpdates,
  applyManagedAction,
} from '../../infrastructure/aws/eb.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/environments
router.get('/environments', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';

    const environments = await getEnvironments(profile, region);
    res.json(environments);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/events
router.get('/events', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const environment = (req.query.environment as string) || '';
    const maxItems = parseInt((req.query.maxItems as string) || '50', 10);

    if (!environment || environment.length < 4) {
      res.status(400).json({
        error: 'environment parameter is required (min 4 chars)',
        type: 'ValidationError',
      });
      return;
    }

    const events = await getEvents(profile, region, environment, maxItems);
    res.json(events);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/eb/environment', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const environmentName = (req.query.environmentName as string) || '';
    res.json(await getEnvironmentDetail(profile, region, environmentName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/restart', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName } = req.body || {};
    if (!environmentName) {
      res.status(400).json({ error: 'environmentName is required' });
      return;
    }
    await restartAppServer(profile, region, environmentName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/rebuild', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName } = req.body || {};
    if (!environmentName) {
      res.status(400).json({ error: 'environmentName is required' });
      return;
    }
    await rebuildEnvironment(profile, region, environmentName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/terminate', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName } = req.body || {};
    if (!environmentName) {
      res.status(400).json({ error: 'environmentName is required' });
      return;
    }
    await terminateEnvironment(profile, region, environmentName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/swap-cname', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { sourceEnvironmentName, destinationEnvironmentName } = req.body || {};
    if (!sourceEnvironmentName || !destinationEnvironmentName) {
      res.status(400).json({ error: 'sourceEnvironmentName and destinationEnvironmentName are required' });
      return;
    }
    await swapEnvironmentCnames(profile, region, sourceEnvironmentName, destinationEnvironmentName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/eb/environment/variable', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName, key, value } = req.body || {};
    if (!environmentName || !key) {
      res.status(400).json({ error: 'environmentName and key are required' });
      return;
    }
    res.json(await setEnvironmentVariable(profile, region, environmentName, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/variable/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName, key } = req.body || {};
    if (!environmentName || !key) {
      res.status(400).json({ error: 'environmentName and key are required' });
      return;
    }
    res.json(await removeEnvironmentVariable(profile, region, environmentName, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName, environmentArn, key, value } = req.body || {};
    if (!environmentName || !environmentArn || !key) {
      res.status(400).json({ error: 'environmentName, environmentArn and key are required' });
      return;
    }
    res.json(await addEnvironmentTag(profile, region, environmentName, environmentArn, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environment/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { environmentName, environmentArn, key } = req.body || {};
    if (!environmentName || !environmentArn || !key) {
      res.status(400).json({ error: 'environmentName, environmentArn and key are required' });
      return;
    }
    res.json(await removeEnvironmentTag(profile, region, environmentName, environmentArn, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/eb/environments/clone', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { sourceEnvironmentName, newEnvironmentName, cnamePrefix } = req.body || {};
    if (!sourceEnvironmentName || !newEnvironmentName) {
      res.status(400).json({ error: 'sourceEnvironmentName and newEnvironmentName are required' });
      return;
    }
    res.json(await cloneEnvironment(profile, region, { sourceEnvironmentName, newEnvironmentName, cnamePrefix: cnamePrefix || undefined }));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/eb/environment/health', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const environmentName = req.query.environmentName as string;
  if (rejectMissing(res, { environmentName })) return;
  await respond(res, () => getEnvironmentHealth(profile, region, environmentName));
});

router.get('/eb/environment/resources', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const environmentName = req.query.environmentName as string;
  if (rejectMissing(res, { environmentName })) return;
  await respond(res, () => getEnvironmentResources(profile, region, environmentName));
});

router.get('/eb/environment/configuration', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const environmentName = req.query.environmentName as string;
  if (rejectMissing(res, { environmentName })) return;
  await respond(res, () => getEnvironmentConfiguration(profile, region, environmentName));
});

router.get('/eb/application/versions', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const applicationName = req.query.applicationName as string;
  if (rejectMissing(res, { applicationName })) return;
  await respond(res, () => listApplicationVersions(profile, region, applicationName));
});

router.post('/eb/environment/deploy', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { environmentName, versionLabel } = req.body || {};
  if (rejectMissing(res, { environmentName, versionLabel })) return;
  await respond(res, () => deployApplicationVersion(profile, region, environmentName, versionLabel));
});

router.post('/eb/environment/logs', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { environmentName, infoType } = req.body || {};
  if (rejectMissing(res, { environmentName })) return;
  if (infoType !== 'tail' && infoType !== 'bundle') {
    res.status(400).json({ error: 'infoType must be tail or bundle' });
    return;
  }
  await respond(res, () => fetchEnvironmentLogs(profile, region, environmentName, infoType));
});

router.get('/eb/environment/managed-updates', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const environmentName = req.query.environmentName as string;
  if (rejectMissing(res, { environmentName })) return;
  await respond(res, () => getManagedUpdates(profile, region, environmentName));
});

router.post('/eb/environment/managed-updates/apply', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { environmentName, actionId } = req.body || {};
  if (rejectMissing(res, { environmentName, actionId })) return;
  await respond(res, () => applyManagedAction(profile, region, environmentName, actionId));
});

export default router;
