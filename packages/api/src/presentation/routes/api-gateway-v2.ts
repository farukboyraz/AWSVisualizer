import { Router } from 'express';
import {
  listHttpApis,
  getHttpApiDetail,
  deployHttpApi,
  deleteHttpApi,
  addHttpApiTag,
  removeHttpApiTag,
} from '../../infrastructure/aws/api-gateway-v2.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

// API Gateway v2 (HTTP + WebSocket APIs). REST APIs live under /apigateway/*.
const router = Router();

function pr(req: { query: Record<string, unknown> }) {
  return { profile: (req.query.profile as string) || '', region: (req.query.region as string) || '' };
}

router.get('/apigatewayv2/apis', async (req, res) => {
  try {
    const { profile, region } = pr(req);
    res.json(await listHttpApis(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/apigatewayv2/api', async (req, res) => {
  try {
    const { profile, region } = pr(req);
    const apiId = (req.query.apiId as string) || '';
    if (!apiId) {
      res.status(400).json({ error: 'apiId is required' });
      return;
    }
    res.json(await getHttpApiDetail(profile, region, apiId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigatewayv2/api/deploy', async (req, res) => {
  try {
    const { profile, region } = pr(req);
    const { apiId, stageName, description } = req.body || {};
    if (!apiId || !stageName) {
      res.status(400).json({ error: 'apiId and stageName are required' });
      return;
    }
    res.json(await deployHttpApi(profile, region, apiId, stageName, description));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigatewayv2/api/delete', async (req, res) => {
  try {
    const { profile, region } = pr(req);
    const { apiId } = req.body || {};
    if (!apiId) {
      res.status(400).json({ error: 'apiId is required' });
      return;
    }
    await deleteHttpApi(profile, region, apiId);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigatewayv2/api/tags', async (req, res) => {
  try {
    const { profile, region } = pr(req);
    const { apiId, key, value } = req.body || {};
    if (!apiId || !key) {
      res.status(400).json({ error: 'apiId and key are required' });
      return;
    }
    res.json(await addHttpApiTag(profile, region, apiId, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/apigatewayv2/api/tags/remove', async (req, res) => {
  try {
    const { profile, region } = pr(req);
    const { apiId, key } = req.body || {};
    if (!apiId || !key) {
      res.status(400).json({ error: 'apiId and key are required' });
      return;
    }
    res.json(await removeHttpApiTag(profile, region, apiId, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
