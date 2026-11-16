import { Router } from 'express';
import { execFile } from 'child_process';
import {
  appendAccessKeyProfile,
  ensureProfileSection,
  isValidProfileName,
  parseAwsConfig,
  profileKind,
} from '../../infrastructure/aws/config-parser.js';
import { invalidateCredentials } from '../../infrastructure/aws/credential-cache.js';
import { getCallerIdentity } from '../../infrastructure/aws/sts.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

// Personal AWS accounts: accounts the user signs in to directly (root or IAM
// user), outside IAM Identity Center. Two ways, like the AWS CLI:
//  - `aws login` (recommended, CLI >= 2.32): browser sign-in with console
//    credentials, short-lived credentials refreshed automatically.
//  - IAM access keys stored in ~/.aws/credentials.
const router = Router();

const REGION = /^[a-z]{2}(-[a-z]+)+-\d$/;

function cliVersion(): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile('aws', ['--version'], { timeout: 10000 }, (error, stdout, stderr) => {
      if (error) return resolve(undefined);
      const match = `${stdout} ${stderr}`.match(/aws-cli\/(\d+\.\d+\.\d+)/);
      resolve(match?.[1]);
    });
  });
}

function supportsAwsLogin(version: string | undefined): boolean {
  if (!version) return false;
  const [major, minor] = version.split('.').map(Number);
  return major > 2 || (major === 2 && minor >= 32);
}

router.get('/personal-accounts', async (_req, res) => {
  try {
    const version = await cliVersion();
    const { profiles } = parseAwsConfig();
    res.json({
      cliVersion: version,
      awsLoginSupported: supportsAwsLogin(version),
      accounts: profiles
        .map((p) => ({ profile: p.name, kind: profileKind(p), region: p.region }))
        .filter((p) => p.kind === 'login' || p.kind === 'keys' || p.kind === 'process'),
    });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

/** Runs `aws login --profile <name> --region <region>` (opens the browser). */
router.post('/personal-accounts/login', async (req, res) => {
  try {
    const { profile, region } = req.body || {};
    if (typeof profile !== 'string' || !isValidProfileName(profile)) {
      res.status(400).json({ error: 'Profile name may only contain letters, digits, ".", "-" and "_"' });
      return;
    }
    if (typeof region !== 'string' || !REGION.test(region)) {
      res.status(400).json({ error: 'A valid region is required, e.g. eu-west-1' });
      return;
    }
    const existing = parseAwsConfig().profiles.find((p) => p.name === profile);
    if (existing && profileKind(existing) !== 'login' && profileKind(existing) !== 'other') {
      res.status(400).json({ error: `Profile "${profile}" already exists and uses ${profileKind(existing) === 'sso' ? 'SSO' : 'access keys'}` });
      return;
    }
    if (!supportsAwsLogin(await cliVersion())) {
      res.status(400).json({ error: 'aws login needs AWS CLI 2.32.0 or newer - update the AWS CLI, or use access keys.' });
      return;
    }
    // Region first, so `aws login` doesn't stop to ask for it.
    ensureProfileSection(profile, region);
    await new Promise<void>((resolve, reject) => {
      execFile('aws', ['login', '--profile', profile, '--region', region], { timeout: 300000 }, (error, _stdout, stderr) => {
        if (error) reject(new Error((stderr || error.message).trim()));
        else resolve();
      });
    });
    invalidateCredentials(profile);
    const identity = await getCallerIdentity(profile, region);
    res.json({ profile, identity });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

/** Saves IAM user access keys as a profile, then checks them with STS. */
router.post('/personal-accounts/access-keys', async (req, res) => {
  try {
    const { profile, accessKeyId, secretAccessKey, region } = req.body || {};
    if (typeof profile !== 'string' || !isValidProfileName(profile)) {
      res.status(400).json({ error: 'Profile name may only contain letters, digits, ".", "-" and "_"' });
      return;
    }
    if (typeof accessKeyId !== 'string' || !/^(AKIA|ASIA)[A-Z0-9]{12,}$/.test(accessKeyId.trim())) {
      res.status(400).json({ error: 'That does not look like an access key ID (AKIA...)' });
      return;
    }
    if (typeof secretAccessKey !== 'string' || secretAccessKey.trim().length < 30) {
      res.status(400).json({ error: 'The secret access key is missing or too short' });
      return;
    }
    if (typeof region !== 'string' || !REGION.test(region)) {
      res.status(400).json({ error: 'A valid region is required, e.g. eu-west-1' });
      return;
    }
    if (parseAwsConfig().profiles.some((p) => p.name === profile)) {
      res.status(400).json({ error: `A profile named "${profile}" already exists` });
      return;
    }
    appendAccessKeyProfile(profile, accessKeyId.trim(), secretAccessKey.trim());
    ensureProfileSection(profile, region);
    invalidateCredentials(profile);
    try {
      const identity = await getCallerIdentity(profile, region);
      res.json({ profile, identity });
    } catch (err: any) {
      res.json({ profile, warning: `Saved, but AWS rejected the keys: ${err.message || err}` });
    }
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
