import { Router } from 'express';
import {
  listKeys,
  getKeyDetail,
  getKeyPolicy,
  updateKeyPolicy,
  setKeyEnabled,
  setKeyRotation,
  scheduleKeyDeletion,
  cancelKeyDeletion,
  addAlias,
  removeAlias,
  addKeyTag,
  removeKeyTag,
} from '../../infrastructure/aws/kms.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

router.get('/kms/keys', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    res.json(await listKeys(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/kms/key', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const keyId = (req.query.keyId as string) || '';
    res.json(await getKeyDetail(profile, region, keyId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/kms/key/policy', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const keyId = (req.query.keyId as string) || '';
    const policy = await getKeyPolicy(profile, region, keyId);
    res.json({ policy });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/kms/key/policy', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, policy } = req.body || {};
    if (!keyId || !policy) {
      res.status(400).json({ error: 'keyId and policy are required' });
      return;
    }
    await updateKeyPolicy(profile, region, keyId, policy);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/kms/key/enabled', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, enabled } = req.body || {};
    if (!keyId || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'keyId and enabled are required' });
      return;
    }
    res.json(await setKeyEnabled(profile, region, keyId, enabled));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/kms/key/rotation', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, enabled, rotationPeriodInDays } = req.body || {};
    if (!keyId || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'keyId and enabled are required' });
      return;
    }
    if (rotationPeriodInDays !== undefined && (!Number.isInteger(rotationPeriodInDays) || rotationPeriodInDays < 90 || rotationPeriodInDays > 2560)) {
      res.status(400).json({ error: 'rotationPeriodInDays must be an integer between 90 and 2560' });
      return;
    }
    res.json(await setKeyRotation(profile, region, keyId, enabled, rotationPeriodInDays));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/kms/key/aliases', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, aliasName } = req.body || {};
    if (!keyId || !aliasName) {
      res.status(400).json({ error: 'keyId and aliasName are required' });
      return;
    }
    res.json(await addAlias(profile, region, keyId, aliasName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/kms/key/aliases/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, aliasName } = req.body || {};
    if (!keyId || !aliasName) {
      res.status(400).json({ error: 'keyId and aliasName are required' });
      return;
    }
    res.json(await removeAlias(profile, region, keyId, aliasName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/kms/key/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, key, value } = req.body || {};
    if (!keyId || !key) {
      res.status(400).json({ error: 'keyId and key are required' });
      return;
    }
    res.json(await addKeyTag(profile, region, keyId, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/kms/key/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, key } = req.body || {};
    if (!keyId || !key) {
      res.status(400).json({ error: 'keyId and key are required' });
      return;
    }
    res.json(await removeKeyTag(profile, region, keyId, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/kms/key/deletion', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId, pendingWindowInDays } = req.body || {};
    if (!keyId || !Number.isInteger(pendingWindowInDays) || pendingWindowInDays < 7 || pendingWindowInDays > 30) {
      res.status(400).json({ error: 'keyId and pendingWindowInDays (7-30) are required' });
      return;
    }
    res.json(await scheduleKeyDeletion(profile, region, keyId, pendingWindowInDays));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/kms/key/deletion/cancel', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { keyId } = req.body || {};
    if (!keyId) {
      res.status(400).json({ error: 'keyId is required' });
      return;
    }
    res.json(await cancelKeyDeletion(profile, region, keyId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
