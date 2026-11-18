import { STSClient, GetCallerIdentityCommand } from '@aws-sdk/client-sts';
import { cachedCredentials, invalidateCredentials } from './credential-cache.js';
import type { CallerIdentity } from '../../domain/entities/index.js';
import { loadConfig, getProfileSessions, saveProfileSessions } from '../../config/index.js';
import { parseAwsConfig, normalizeStartUrl } from './config-parser.js';
import { isAuthError, isTransientError } from './credentials.js';
import { validTokenExpiries } from './sso.js';
import type { AwsProfile, SsoSession } from '../../domain/entities/index.js';

function createStsClient(profile: string, region: string): STSClient {
  return new STSClient({
    region,
    credentials: cachedCredentials(profile),
  });
}

export async function getCallerIdentity(
  profile: string,
  region: string
): Promise<CallerIdentity> {
  const client = createStsClient(profile, region);
  const command = new GetCallerIdentityCommand({});
  const response = await client.send(command);

  return {
    account: response.Account || '',
    arn: response.Arn || '',
    userId: response.UserId || '',
  };
}

export interface ProfileCheck {
  profile: string;
  region: string;
  accountId: string;
  roleName: string;
  ssoSession?: string;
  valid: boolean;
  /** AWS couldn't be asked just now (throttled / offline): `valid` is the
   * best guess from the SSO token and the last saved check, not a fresh answer. */
  unverified?: boolean;
  /** When the profile's SSO sign-in runs out (ISO time), when known. */
  expiresAt?: string;
  identity?: CallerIdentity;
  error?: string;
}

const CHECK_CONCURRENCY = 4;
const RETRY_DELAY_MS = 1200;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** The start URL a profile signs in through (its sso-session's, or its own legacy one). */
function startUrlOf(profile: AwsProfile, sessions: SsoSession[]): string | undefined {
  const raw = profile.sso_session ? sessions.find((s) => s.name === profile.sso_session)?.sso_start_url : profile.sso_start_url;
  return raw ? normalizeStartUrl(raw) || raw : undefined;
}

/**
 * Which profiles are signed in. Only a real "not authorized" answer marks
 * a profile expired:
 * - at most 4 profiles are checked at a time (all at once made the SSO
 *   portal throttle, and a throttled check used to read as "expired");
 * - a throttled / timed-out / offline check is tried once more, and if it
 *   still can't reach AWS the profile keeps its last saved state (or, for
 *   SSO, counts as signed in while its token in ~/.aws/sso/cache is valid);
 * - an auth error while the SSO token is still valid drops the cached role
 *   credentials and asks once more (a login in the terminal renews them);
 * - any other error isn't about the sign-in, so the profile stays usable.
 * Each result is saved per profile in ~/.awsvisualizer (`profileSessions`)
 * with the SSO token's expiry.
 */
export async function checkAllProfiles(): Promise<ProfileCheck[]> {
  const config = loadConfig();
  const { profiles, ssoSessions } = parseAwsConfig();
  const tokens = validTokenExpiries();
  const saved = getProfileSessions();

  const checkOne = async (profile: AwsProfile): Promise<ProfileCheck> => {
    const region = profile.region || config.aws.defaultRegion;
    const startUrl = startUrlOf(profile, ssoSessions);
    const expiresAt = startUrl ? tokens.get(startUrl) : undefined;
    const base = {
      profile: profile.name,
      region,
      accountId: profile.sso_account_id || '',
      roleName: profile.sso_role_name || '',
      ssoSession: profile.sso_session,
      ...(expiresAt ? { expiresAt } : {}),
    };
    let lastError: unknown;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const identity = await getCallerIdentity(profile.name, region);
        return { ...base, accountId: base.accountId || identity.account, valid: true, identity };
      } catch (err) {
        lastError = err;
        if (isTransientError(err)) {
          await sleep(RETRY_DELAY_MS);
        } else if (isAuthError(err) && expiresAt && attempt === 0) {
          invalidateCredentials(profile.name);
        } else {
          break;
        }
      }
    }
    const message = (lastError as Error)?.message || 'Unknown error';
    if (isTransientError(lastError)) {
      const previous = saved[profile.name];
      const stillSignedIn = expiresAt ? true : previous ? previous.valid && (!previous.expiresAt || Date.parse(previous.expiresAt) > Date.now()) : true;
      return { ...base, valid: stillSignedIn, unverified: true, error: message };
    }
    if (!isAuthError(lastError)) return { ...base, valid: true, unverified: true, error: message };
    return { ...base, valid: false, error: message };
  };

  // A small pool instead of every profile at once.
  const results: ProfileCheck[] = new Array(profiles.length);
  let next = 0;
  const worker = async () => {
    while (next < profiles.length) {
      const index = next++;
      results[index] = await checkOne(profiles[index]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(CHECK_CONCURRENCY, profiles.length) }, worker));

  const now = new Date().toISOString();
  saveProfileSessions(
    Object.fromEntries(
      results.map((r) => [
        r.profile,
        {
          checkedAt: r.unverified ? saved[r.profile]?.checkedAt ?? now : now,
          valid: r.valid,
          ...(r.expiresAt ? { expiresAt: r.expiresAt } : {}),
          ...(r.error && !r.valid ? { error: r.error } : {}),
        },
      ]),
    ),
  );
  return results;
}
