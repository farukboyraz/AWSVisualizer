import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { SSOClient, ListAccountsCommand, ListAccountRolesCommand } from '@aws-sdk/client-sso';
import { parseAwsConfig } from './config-parser.js';
import type { AccessibleEnvironment } from '../../domain/entities/index.js';

interface CachedSsoToken {
  accessToken: string;
  startUrl: string;
  region: string;
  expiresAt: string;
}

function getSsoCachePath(): string {
  return join(homedir(), '.aws', 'sso', 'cache');
}

function getValidCachedTokens(): CachedSsoToken[] {
  const cachePath = getSsoCachePath();

  let files: string[];
  try {
    files = readdirSync(cachePath).filter((f) => f.endsWith('.json'));
  } catch {
    return [];
  }

  const now = new Date();
  const tokens: CachedSsoToken[] = [];

  for (const file of files) {
    try {
      const content = readFileSync(join(cachePath, file), 'utf-8');
      const data = JSON.parse(content);
      if (!data.accessToken || !data.expiresAt || !data.startUrl || !data.region) continue;
      if (new Date(data.expiresAt) <= now) continue;

      tokens.push({
        accessToken: data.accessToken,
        startUrl: data.startUrl,
        region: data.region,
        expiresAt: data.expiresAt,
      });
    } catch {
      continue;
    }
  }

  return tokens;
}

async function listRolesForAccount(
  client: SSOClient,
  accessToken: string,
  accountId: string
): Promise<string[]> {
  const roleNames: string[] = [];
  let nextToken: string | undefined;

  do {
    const response = await client.send(
      new ListAccountRolesCommand({ accessToken, accountId, nextToken })
    );
    for (const role of response.roleList || []) {
      if (role.roleName) roleNames.push(role.roleName);
    }
    nextToken = response.nextToken;
  } while (nextToken);

  return roleNames;
}

/**
 * Enumerates every AWS account + role the current SSO identity has access
 * to, via the SSO ListAccounts/ListAccountRoles APIs - not limited to what
 * happens to have a named profile in ~/.aws/config. Each result is
 * cross-referenced against configured profiles so the caller can tell which
 * ones are ready to use and which still need a profile set up for them.
 */
export async function listAccessibleEnvironments(): Promise<AccessibleEnvironment[]> {
  const tokens = getValidCachedTokens();
  if (tokens.length === 0) return [];

  const { profiles, ssoSessions } = parseAwsConfig();

  const results = new Map<string, AccessibleEnvironment>();

  for (const token of tokens) {
    const ssoSession = ssoSessions.find((s) => s.sso_start_url === token.startUrl);
    const client = new SSOClient({ region: token.region });

    let nextToken: string | undefined;
    do {
      const response = await client.send(
        new ListAccountsCommand({ accessToken: token.accessToken, nextToken })
      );

      for (const account of response.accountList || []) {
        if (!account.accountId) continue;
        const roleNames = await listRolesForAccount(client, token.accessToken, account.accountId);

        for (const roleName of roleNames) {
          const dedupeKey = `${account.accountId}:${roleName}`;
          if (results.has(dedupeKey)) continue;

          const matchedProfile = profiles.find(
            (p) => p.sso_account_id === account.accountId && p.sso_role_name === roleName
          );

          results.set(dedupeKey, {
            accountId: account.accountId,
            accountName: account.accountName || account.accountId,
            roleName,
            ssoSessionName: ssoSession?.name || '',
            ssoRegion: token.region,
            configuredProfileName: matchedProfile?.name,
          });
        }
      }

      nextToken = response.nextToken;
    } while (nextToken);
  }

  return Array.from(results.values()).sort((a, b) => a.accountName.localeCompare(b.accountName));
}
