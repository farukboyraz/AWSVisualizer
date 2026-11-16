import { Router } from 'express';
import {
  listFunctions,
  getFunctionDetail,
  getFunctionMetrics,
  listCodeEntries,
  getCodeEntryContent,
  exportCodeToLocalDirectory,
  updateFunctionConfig,
  updateEnvironmentVariables,
  invokeFunction,
  listVersions,
  publishVersion,
  listAliases,
  createAlias,
  updateAlias,
  deleteAlias,
  listEventSourceMappings,
  createEventSourceMapping,
  setEventSourceMappingEnabled,
  deleteEventSourceMapping,
  setReservedConcurrency,
  removeReservedConcurrency,
  addFunctionTag,
  removeFunctionTag,
  deleteFunction,
  createFunctionFromInlineCode,
} from '../../infrastructure/aws/lambda.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/lambda/functions
router.get('/lambda/functions', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listFunctions(profile, region));
});

router.get('/lambda/function', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    res.json(await getFunctionDetail(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/lambda/function/code/entries', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    res.json(await listCodeEntries(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/lambda/function/code/entry', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    const path = (req.query.path as string) || '';
    res.json(await getCodeEntryContent(profile, region, functionName, path));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/code/export', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    const path = await exportCodeToLocalDirectory(profile, region, functionName);
    res.json({ path });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/lambda/function/metrics', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    res.json(await getFunctionMetrics(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/lambda/function/config', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, memorySize, timeout, description } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    res.json(await updateFunctionConfig(profile, region, functionName, { memorySize, timeout, description }));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/lambda/function/environment', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, variables } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    res.json(await updateEnvironmentVariables(profile, region, functionName, variables || {}));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/invoke', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, payload } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    res.json(await invokeFunction(profile, region, functionName, payload || '{}'));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/lambda/function/versions', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    res.json(await listVersions(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/versions', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, description } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    res.json(await publishVersion(profile, region, functionName, description));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/lambda/function/aliases', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    res.json(await listAliases(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/aliases', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, name, functionVersion, description } = req.body || {};
    if (!functionName || !name || !functionVersion) {
      res.status(400).json({ error: 'functionName, name and functionVersion are required' });
      return;
    }
    res.json(await createAlias(profile, region, functionName, name, functionVersion, description));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/lambda/function/aliases', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, name, functionVersion, description } = req.body || {};
    if (!functionName || !name || !functionVersion) {
      res.status(400).json({ error: 'functionName, name and functionVersion are required' });
      return;
    }
    res.json(await updateAlias(profile, region, functionName, name, functionVersion, description));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/aliases/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, name } = req.body || {};
    if (!functionName || !name) {
      res.status(400).json({ error: 'functionName and name are required' });
      return;
    }
    res.json(await deleteAlias(profile, region, functionName, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/lambda/function/triggers', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const functionName = (req.query.functionName as string) || '';
    res.json(await listEventSourceMappings(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/triggers', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, eventSourceArn, batchSize, startingPosition } = req.body || {};
    if (!functionName || !eventSourceArn) {
      res.status(400).json({ error: 'functionName and eventSourceArn are required' });
      return;
    }
    res.json(await createEventSourceMapping(profile, region, functionName, eventSourceArn, batchSize, startingPosition));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/lambda/function/triggers', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, uuid, enabled } = req.body || {};
    if (!functionName || !uuid || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'functionName, uuid and enabled are required' });
      return;
    }
    res.json(await setEventSourceMappingEnabled(profile, region, functionName, uuid, enabled));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/triggers/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, uuid } = req.body || {};
    if (!functionName || !uuid) {
      res.status(400).json({ error: 'functionName and uuid are required' });
      return;
    }
    res.json(await deleteEventSourceMapping(profile, region, functionName, uuid));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/lambda/function/concurrency', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, reservedConcurrentExecutions } = req.body || {};
    if (!functionName || typeof reservedConcurrentExecutions !== 'number') {
      res.status(400).json({ error: 'functionName and reservedConcurrentExecutions are required' });
      return;
    }
    res.json(await setReservedConcurrency(profile, region, functionName, reservedConcurrentExecutions));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/concurrency/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    res.json(await removeReservedConcurrency(profile, region, functionName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionArn, functionName, key, value } = req.body || {};
    if (!functionArn || !functionName || !key) {
      res.status(400).json({ error: 'functionArn, functionName and key are required' });
      return;
    }
    res.json(await addFunctionTag(profile, region, functionArn, functionName, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionArn, functionName, key } = req.body || {};
    if (!functionArn || !functionName || !key) {
      res.status(400).json({ error: 'functionArn, functionName and key are required' });
      return;
    }
    res.json(await removeFunctionTag(profile, region, functionArn, functionName, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName } = req.body || {};
    if (!functionName) {
      res.status(400).json({ error: 'functionName is required' });
      return;
    }
    await deleteFunction(profile, region, functionName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/lambda/function/create', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { functionName, runtime, handler, role, code, memorySize, timeout, description } = req.body || {};
    if (!functionName || !runtime || !handler || !role || !code) {
      res.status(400).json({ error: 'functionName, runtime, handler, role and code are required' });
      return;
    }
    res.json(await createFunctionFromInlineCode(profile, region, { functionName, runtime, handler, role, code, memorySize, timeout, description }));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
