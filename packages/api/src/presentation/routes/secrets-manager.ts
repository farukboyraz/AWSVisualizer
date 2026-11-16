import { Router } from 'express';
import {
  listSecrets,
  getSecretDetail,
  updateSecretDescription,
  addSecretTag,
  removeSecretTag,
  deleteSecret,
  restoreSecret,
  getSecretValue,
  putSecretValue,
  createSecret,
  getResourcePolicy,
  putResourcePolicy,
  deleteResourcePolicy,
  updateRotation,
  rotateSecretNow,
  cancelRotation,
} from '../../infrastructure/aws/secrets-manager.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

router.get('/secretsmanager/secrets', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    res.json(await listSecrets(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secrets', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, description, secretString, kmsKeyId, tags } = req.body || {};
    if (!name || typeof secretString !== 'string' || !secretString) {
      res.status(400).json({ error: 'name and secretString are required' });
      return;
    }
    res.json(await createSecret(profile, region, name, description, secretString, kmsKeyId, tags));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/secretsmanager/secret', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    res.json(await getSecretDetail(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/secretsmanager/secret/value', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    res.json(await getSecretValue(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/secretsmanager/secret/value', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, secretString } = req.body || {};
    if (!name || typeof secretString !== 'string' || secretString === '') {
      res.status(400).json({ error: 'name and a non-empty secretString are required' });
      return;
    }
    res.json(await putSecretValue(profile, region, name, secretString));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/secretsmanager/secret/description', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, description } = req.body || {};
    if (!name || typeof description !== 'string') {
      res.status(400).json({ error: 'name and description are required' });
      return;
    }
    res.json(await updateSecretDescription(profile, region, name, description));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, key, value } = req.body || {};
    if (!name || !key) {
      res.status(400).json({ error: 'name and key are required' });
      return;
    }
    res.json(await addSecretTag(profile, region, name, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, key } = req.body || {};
    if (!name || !key) {
      res.status(400).json({ error: 'name and key are required' });
      return;
    }
    res.json(await removeSecretTag(profile, region, name, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, recoveryWindowInDays } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    const window = typeof recoveryWindowInDays === 'number' ? recoveryWindowInDays : 30;
    await deleteSecret(profile, region, name, window);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/restore', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    res.json(await restoreSecret(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/secretsmanager/secret/policy', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    res.json(await getResourcePolicy(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/secretsmanager/secret/policy', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, policy } = req.body || {};
    if (!name || typeof policy !== 'string') {
      res.status(400).json({ error: 'name and policy are required' });
      return;
    }
    res.json(await putResourcePolicy(profile, region, name, policy));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/policy/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    await deleteResourcePolicy(profile, region, name);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/rotation', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name, rotationLambdaARN, automaticallyAfterDays } = req.body || {};
    if (!name || !rotationLambdaARN || typeof automaticallyAfterDays !== 'number') {
      res.status(400).json({ error: 'name, rotationLambdaARN and automaticallyAfterDays are required' });
      return;
    }
    res.json(await updateRotation(profile, region, name, rotationLambdaARN, automaticallyAfterDays));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/rotation/rotate-now', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    res.json(await rotateSecretNow(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/secretsmanager/secret/rotation/cancel', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    res.json(await cancelRotation(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
