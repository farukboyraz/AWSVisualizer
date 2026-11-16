import { Router } from 'express';
import {
  listRestApis,
  getResources,
  deleteResource,
  deleteMethod,
  getStages,
  deployApi,
  deleteStage,
  updateRestApi,
  deleteRestApi,
} from '../../infrastructure/aws/api-gateway.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

router.get('/apigateway/apis', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    res.json(await listRestApis(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/apigateway/resources', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const apiId = (req.query.apiId as string) || '';
    res.json(await getResources(profile, region, apiId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigateway/resources/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { apiId, resourceId } = req.body || {};
    if (!apiId || !resourceId) {
      res.status(400).json({ error: 'apiId and resourceId are required' });
      return;
    }
    await deleteResource(profile, region, apiId, resourceId);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigateway/methods/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { apiId, resourceId, httpMethod } = req.body || {};
    if (!apiId || !resourceId || !httpMethod) {
      res.status(400).json({ error: 'apiId, resourceId and httpMethod are required' });
      return;
    }
    await deleteMethod(profile, region, apiId, resourceId, httpMethod);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/apigateway/stages', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const apiId = (req.query.apiId as string) || '';
    res.json(await getStages(profile, region, apiId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigateway/deploy', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { apiId, stageName, description } = req.body || {};
    if (!apiId || !stageName) {
      res.status(400).json({ error: 'apiId and stageName are required' });
      return;
    }
    res.json(await deployApi(profile, region, apiId, stageName, description));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigateway/stages/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { apiId, stageName } = req.body || {};
    if (!apiId || !stageName) {
      res.status(400).json({ error: 'apiId and stageName are required' });
      return;
    }
    await deleteStage(profile, region, apiId, stageName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/apigateway/api', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { apiId, name, description } = req.body || {};
    if (!apiId) {
      res.status(400).json({ error: 'apiId is required' });
      return;
    }
    const result = await updateRestApi(profile, region, apiId, name, description);
    if (!result) {
      res.status(404).json({ error: 'API not found' });
      return;
    }
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigateway/api/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { apiId } = req.body || {};
    if (!apiId) {
      res.status(400).json({ error: 'apiId is required' });
      return;
    }
    await deleteRestApi(profile, region, apiId);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
