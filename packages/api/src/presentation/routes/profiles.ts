import { Router } from 'express';
import { listAccessibleEnvironments } from '../../infrastructure/aws/sso-accounts.js';
import { appendProfile } from '../../infrastructure/aws/config-parser.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/accessible-environments
router.get('/accessible-environments', async (_req, res) => {
  try {
    const environments = await listAccessibleEnvironments();
    res.json({ environments });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/profiles
router.post('/profiles', async (req, res) => {
  try {
    const { name, ssoSessionName, accountId, roleName, region } = req.body || {};

    if (!name || !ssoSessionName || !accountId || !roleName || !region) {
      res.status(400).json({ error: 'name, ssoSessionName, accountId, roleName and region are required' });
      return;
    }

    appendProfile({ name, ssoSessionName, accountId, roleName, region });
    res.json({ success: true, name });
  } catch (err: any) {
    res.status(400).json({ error: err.message || 'Failed to create profile' });
  }
});

export default router;
