import { statSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { fromIni } from '@aws-sdk/credential-providers';
import { parseAwsConfig } from './config-parser.js';

type Provider = ReturnType<typeof fromIni>;
type Credentials = Awaited<ReturnType<Provider>>;

/**
 * One set of resolved credentials per profile, shared by every AWS client.
 *
 * Every service creates a fresh client per request with
 * `fromIni({ ignoreCache: true })` (so a profile added to ~/.aws/config or a
 * fresh `aws sso login` is picked up without restarting). But that means
 * each request resolved credentials from scratch: for an SSO profile that
 * is a `sso:GetRoleCredentials` call to the SSO portal - per request. A
 * paged DynamoDB search, several views loading at once and the profile
 * re-check easily made dozens of those a minute; the portal throttles them
 * (or they time out), the SDK reports that as a credential error, and the
 * app showed "session expired" while `aws` in the terminal (which caches
 * role credentials in ~/.aws/cli/cache) worked fine.
 *
 * Now credentials are resolved once and reused until 5 minutes before they
 * expire. The cache is dropped whenever ~/.aws/config, ~/.aws/credentials
 * or a file in ~/.aws/sso/cache changes, so new profiles and re-logins
 * still take effect immediately - what `ignoreCache` was for.
 */
const REFRESH_BEFORE_EXPIRY_MS = 5 * 60_000;

interface Entry {
  stamp: string;
  credentials?: Credentials;
  pending?: Promise<Credentials>;
}

const entries = new Map<string, Entry>();

function mtime(path: string): number {
  try {
    return statSync(path).mtimeMs;
  } catch {
    return 0;
  }
}

/** Changes whenever the AWS config/credentials files or the SSO token cache change. */
function filesStamp(): string {
  const aws = join(homedir(), '.aws');
  let sso = 0;
  try {
    for (const name of readdirSync(join(aws, 'sso', 'cache'))) sso = Math.max(sso, mtime(join(aws, 'sso', 'cache', name)));
  } catch {
    // no SSO cache yet
  }
  return `${mtime(join(aws, 'config'))}|${mtime(join(aws, 'credentials'))}|${sso}`;
}

function isFresh(credentials: Credentials): boolean {
  return !credentials.expiration || credentials.expiration.getTime() - Date.now() > REFRESH_BEFORE_EXPIRY_MS;
}

/** Drop a profile's cached credentials (e.g. after AWS rejected them as expired). */
export function invalidateCredentials(profile: string): void {
  entries.delete(profile);
}

export function cachedCredentials(profile: string): Provider {
  return async () => {
    const stamp = filesStamp();
    let entry = entries.get(profile);
    if (!entry || entry.stamp !== stamp) {
      entry = { stamp };
      entries.set(profile, entry);
    }
    if (entry.credentials && isFresh(entry.credentials)) return entry.credentials;
    // Concurrent requests share one resolution instead of each asking SSO.
    if (!entry.pending) {
      const current = entry;
      current.pending = resolveCredentials(profile)
        .then((credentials) => {
          current.credentials = credentials;
          return credentials;
        })
        .finally(() => {
          current.pending = undefined;
        });
    }
    return entry.pending!;
  };
}

/**
 * `aws login` profiles (console credentials, `login_session`) aren't
 * understood by this SDK version, so - as AWS recommends for older SDKs -
 * the CLI resolves them (`aws configure export-credentials`) and refreshes
 * them from its refresh token. Everything else goes through `fromIni`.
 */
function resolveCredentials(profile: string): Promise<Credentials> {
  const entry = parseAwsConfig().profiles.find((p) => p.name === profile);
  if (entry?.login_session) return exportCliCredentials(profile);
  return fromIni({ profile, ignoreCache: true })();
}

function exportCliCredentials(profile: string): Promise<Credentials> {
  return new Promise((resolve, reject) => {
    execFile('aws', ['configure', 'export-credentials', '--profile', profile, '--format', 'process'], { timeout: 30000 }, (error, stdout, stderr) => {
      if (error) {
        const message = (stderr || error.message).trim();
        reject(Object.assign(new Error(message || 'Could not get credentials from aws login'), { name: 'CredentialsProviderError' }));
        return;
      }
      try {
        const data = JSON.parse(stdout) as { AccessKeyId: string; SecretAccessKey: string; SessionToken?: string; Expiration?: string };
        resolve({
          accessKeyId: data.AccessKeyId,
          secretAccessKey: data.SecretAccessKey,
          sessionToken: data.SessionToken,
          expiration: data.Expiration ? new Date(data.Expiration) : undefined,
        });
      } catch {
        reject(new Error('Unexpected output from aws configure export-credentials'));
      }
    });
  });
}
