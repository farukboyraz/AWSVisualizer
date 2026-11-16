import { readdirSync, readFileSync, statSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { normalizeStartUrl } from './config-parser.js';
import type { SsoStatus } from '../../domain/entities/index.js';

function getSsoCachePath(): string {
  return join(homedir(), '.aws', 'sso', 'cache');
}

export async function checkSsoStatus(): Promise<SsoStatus> {
  const cachePath = getSsoCachePath();

  let files: string[];
  try {
    files = readdirSync(cachePath).filter((f) => f.endsWith('.json'));
  } catch {
    return { loggedIn: false };
  }

  const now = new Date();

  for (const file of files) {
    const filePath = join(cachePath, file);
    try {
      const content = readFileSync(filePath, 'utf-8');
      const data = JSON.parse(content);

      if (!data.accessToken || !data.expiresAt) {
        continue;
      }

      const expiresAt = new Date(data.expiresAt);
      if (expiresAt <= now) {
        continue;
      }

      const stat = statSync(filePath);
      const loginTime = stat.mtime.toISOString();

      return {
        loggedIn: true,
        expiresAt: data.expiresAt,
        startUrl: data.startUrl || undefined,
        region: data.region || undefined,
        loginTime,
      };
    } catch {
      continue;
    }
  }

  return { loggedIn: false };
}

/** Unexpired SSO tokens in ~/.aws/sso/cache, keyed by normalized start URL (latest expiry wins). */
export function validTokenExpiries(): Map<string, string> {
  const result = new Map<string, string>();
  let files: string[];
  try {
    files = readdirSync(getSsoCachePath()).filter((f) => f.endsWith('.json'));
  } catch {
    return result;
  }
  const now = Date.now();
  for (const file of files) {
    try {
      const data = JSON.parse(readFileSync(join(getSsoCachePath(), file), 'utf-8'));
      if (!data.accessToken || !data.expiresAt || !data.startUrl) continue;
      if (new Date(data.expiresAt).getTime() <= now) continue;
      const key = normalizeStartUrl(String(data.startUrl)) || String(data.startUrl);
      const previous = result.get(key);
      if (!previous || previous < data.expiresAt) result.set(key, data.expiresAt);
    } catch {
      continue;
    }
  }
  return result;
}
