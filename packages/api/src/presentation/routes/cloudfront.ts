import { Router } from 'express';
import {
  listDistributions,
  getDistributionDetail,
  setDistributionEnabled,
  deleteDistribution,
  addDistributionTag,
  removeDistributionTag,
  listInvalidations,
  getInvalidation,
  createInvalidation,
  normalizeInvalidationPaths,
} from '../../infrastructure/aws/cloudfront.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/cloudfront/distributions
router.get('/cloudfront/distributions', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listDistributions(profile, region));
});

router.get('/cloudfront/distribution', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const id = (req.query.id as string) || '';
    res.json(await getDistributionDetail(profile, region, id));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/cloudfront/distribution/enabled', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { id, enabled } = req.body || {};
    if (!id || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'id and enabled are required' });
      return;
    }
    res.json(await setDistributionEnabled(profile, region, id, enabled));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudfront/distribution/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { id } = req.body || {};
    if (!id) {
      res.status(400).json({ error: 'id is required' });
      return;
    }
    await deleteDistribution(profile, region, id);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudfront/distribution/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { id, key, value } = req.body || {};
    if (!id || !key) {
      res.status(400).json({ error: 'id and key are required' });
      return;
    }
    res.json(await addDistributionTag(profile, region, id, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudfront/distribution/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { id, key } = req.body || {};
    if (!id || !key) {
      res.status(400).json({ error: 'id and key are required' });
      return;
    }
    res.json(await removeDistributionTag(profile, region, id, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudfront/distribution/invalidations', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const id = (req.query.id as string) || '';
    if (!id) {
      res.status(400).json({ error: 'id is required' });
      return;
    }
    res.json(await listInvalidations(profile, region, id));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudfront/distribution/invalidation', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const id = (req.query.id as string) || '';
    const invalidationId = (req.query.invalidationId as string) || '';
    if (!id || !invalidationId) {
      res.status(400).json({ error: 'id and invalidationId are required' });
      return;
    }
    res.json(await getInvalidation(profile, region, id, invalidationId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudfront/distribution/invalidations', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { id, paths } = req.body || {};
    if (!id || !Array.isArray(paths)) {
      res.status(400).json({ error: 'id and paths[] are required' });
      return;
    }
    const cleaned = normalizeInvalidationPaths(paths.map(String));
    if (cleaned.length === 0) {
      res.status(400).json({ error: 'At least one path is required' });
      return;
    }
    const invalid = cleaned.find((p) => !p.startsWith('/'));
    if (invalid) {
      res.status(400).json({ error: `Path must start with "/": ${invalid}` });
      return;
    }
    res.json(await createInvalidation(profile, region, id, cleaned));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
