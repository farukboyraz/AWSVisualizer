import { Router } from 'express';
import { loadConfig } from '../../config/index.js';
import { parseAwsConfig } from '../../infrastructure/aws/config-parser.js';
import { checkSsoStatus } from '../../infrastructure/aws/sso.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/aws-status
router.get('/aws-status', async (_req, res) => {
  try {
    const config = loadConfig();
    const ssoStatus = await checkSsoStatus();
    const { profiles, ssoSessions } = parseAwsConfig();

    res.json({
      loggedIn: ssoStatus.loggedIn,
      expiresAt: ssoStatus.expiresAt,
      startUrl: config.aws.platforms[0]?.startUrl,
      region: config.aws.platforms[0]?.region,
      sessionName: config.aws.platforms[0]?.id,
      loginTime: ssoStatus.loginTime,
      profiles: profiles.map((p) => ({
        name: p.name,
        region: p.region,
        sso_session: p.sso_session,
        sso_account_id: p.sso_account_id,
        sso_role_name: p.sso_role_name,
      })),
      ssoSessions: ssoSessions.map((s) => ({
        name: s.name,
        sso_start_url: s.sso_start_url,
        sso_region: s.sso_region,
      })),
    });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
