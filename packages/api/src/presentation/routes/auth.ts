import { Router } from 'express';
import { exec, execFile } from 'child_process';
import { loadConfig } from '../../config/index.js';
import { parseAwsConfig } from '../../infrastructure/aws/config-parser.js';
import { getCallerIdentity, checkAllProfiles } from '../../infrastructure/aws/sts.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// POST /api/sso-login
// Body (all optional): `profile` - log in the sso-session that profile uses;
// `ssoSession` - log in that session directly. Without either, the first
// configured session is used (the original boot-time behaviour).
//
// The session / profile name is only ever taken from ~/.aws/config itself
// (the request value just selects one) and passed to `aws` as a separate
// argv entry via execFile - never interpolated into a shell command string.
router.post('/sso-login', async (req, res) => {
  try {
    const config = loadConfig();
    const body = req.body || {};
    const { ssoSessions, profiles } = parseAwsConfig();

    let args: string[];

    if (body.profile) {
      const profile = profiles.find((p) => p.name === body.profile);
      if (!profile) {
        res.status(400).json({ error: `Unknown profile: ${body.profile}` });
        return;
      }
      args = profile.sso_session ? ['--sso-session', profile.sso_session] : ['--profile', profile.name];
    } else if (body.ssoSession) {
      const session = ssoSessions.find((s) => s.name === body.ssoSession);
      if (!session) {
        res.status(400).json({ error: `Unknown sso-session: ${body.ssoSession}` });
        return;
      }
      args = ['--sso-session', session.name];
    } else if (config.aws.platforms.length > 0) {
      args = ['--sso-session', config.aws.platforms[0].id];
    } else if (ssoSessions.length > 0) {
      args = ['--sso-session', ssoSessions[0].name];
    } else if (profiles.some((p) => p.sso_session)) {
      args = ['--sso-session', profiles.find((p) => p.sso_session)!.sso_session!];
    } else if (profiles.length > 0) {
      args = ['--profile', profiles[0].name];
    } else {
      res.status(400).json({ error: 'No AWS access portal is configured yet' });
      return;
    }

    await new Promise<string>((resolve, reject) => {
      execFile('aws', ['sso', 'login', ...args], { timeout: 300000 }, (error, stdout, stderr) => {
        if (error) {
          reject(new Error(stderr || error.message));
        } else {
          resolve(stdout);
        }
      });
    });

    res.json({
      success: true,
      command: `aws sso login ${args.join(' ')}`,
    });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// POST /api/sso-logout
router.post('/sso-logout', async (_req, res) => {
  try {
    await new Promise<string>((resolve, reject) => {
      exec('aws sso logout', (error, stdout, stderr) => {
        if (error) {
          reject(new Error(stderr || error.message));
        } else {
          resolve(stdout);
        }
      });
    });

    res.json({ success: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/check-profiles
router.get('/check-profiles', async (_req, res) => {
  try {
    const profileResults = await checkAllProfiles();

    res.json({
      total: profileResults.length,
      valid: profileResults.filter((r) => r.valid).length,
      profiles: profileResults,
    });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// GET /api/caller-identity
router.get('/caller-identity', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';

    const identity = await getCallerIdentity(profile, region);
    res.json(identity);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
