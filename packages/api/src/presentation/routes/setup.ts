import { Router } from 'express';
import { execFile } from 'child_process';
import { enableConfigPersistence, getPlatforms, isConfigPersisted, removePlatform, savePlatform } from '../../config/index.js';
import { ensureSsoSession, normalizeStartUrl, parseAwsConfig, suggestSessionName } from '../../infrastructure/aws/config-parser.js';
import { validTokenExpiries } from '../../infrastructure/aws/sso.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

// First-run setup and access-portal ("platform") management.
const router = Router();

const SSO_REGION = /^[a-z]{2}(-[a-z]+)+-\d$/;

function awsCliAvailable(): Promise<boolean> {
  return new Promise((resolve) => {
    execFile('aws', ['--version'], { timeout: 10000 }, (error) => resolve(!error));
  });
}

function platformsWithStatus() {
  const tokens = validTokenExpiries();
  const { profiles } = parseAwsConfig();
  return getPlatforms().map((p) => {
    const expiresAt = tokens.get(p.startUrl);
    return {
      ...p,
      loggedIn: expiresAt !== undefined,
      expiresAt,
      profileCount: profiles.filter((profile) => profile.sso_session === p.id).length,
    };
  });
}

router.get('/setup', async (_req, res) => {
  try {
    const { ssoSessions } = parseAwsConfig();
    res.json({
      configPersisted: isConfigPersisted(),
      platforms: platformsWithStatus(),
      knownSessions: ssoSessions
        .filter((s) => s.sso_start_url)
        .map((s) => ({ name: s.name, startUrl: normalizeStartUrl(s.sso_start_url!) || s.sso_start_url, region: s.sso_region })),
      awsCliAvailable: await awsCliAvailable(),
    });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/setup/platforms', async (req, res) => {
  try {
    const { startUrl, region, name } = req.body || {};
    const normalized = typeof startUrl === 'string' ? normalizeStartUrl(startUrl) : undefined;
    if (!normalized) {
      res.status(400).json({ error: 'Enter the AWS access portal URL, e.g. https://your-org.awsapps.com/start/#' });
      return;
    }
    if (typeof region !== 'string' || !SSO_REGION.test(region)) {
      res.status(400).json({ error: 'A valid IAM Identity Center region is required, e.g. eu-west-1' });
      return;
    }
    const displayName = typeof name === 'string' && name.trim() ? name.trim() : suggestSessionName(normalized);
    const session = ensureSsoSession(normalized, region, displayName);
    savePlatform({ id: session.name, name: displayName, startUrl: normalized, region: session.region });
    res.json({ platformId: session.name, createdSsoSession: session.created, platforms: platformsWithStatus() });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/setup/platforms/remove', async (req, res) => {
  try {
    const { id } = req.body || {};
    if (typeof id !== 'string' || !id) {
      res.status(400).json({ error: 'id is required' });
      return;
    }
    removePlatform(id);
    res.json({ platforms: platformsWithStatus() });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/setup/persist', async (_req, res) => {
  try {
    enableConfigPersistence();
    res.json({ configPersisted: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
