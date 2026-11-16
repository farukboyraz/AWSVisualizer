import { STSClient, GetCallerIdentityCommand } from '@aws-sdk/client-sts';
import { cachedCredentials } from './credential-cache.js';
import type { CallerIdentity } from '../../domain/entities/index.js';
import { loadConfig } from '../../config/index.js';
import { parseAwsConfig } from './config-parser.js';

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

export async function checkAllProfiles(): Promise<
  {
    profile: string;
    region: string;
    accountId: string;
    roleName: string;
    ssoSession?: string;
    valid: boolean;
    identity?: CallerIdentity;
    error?: string;
  }[]
> {
  const config = loadConfig();
  const { profiles } = parseAwsConfig();

  const results = await Promise.allSettled(
    profiles.map(async (profile) => {
      const region = profile.region || config.aws.defaultRegion;
      try {
        const identity = await getCallerIdentity(profile.name, region);
        return {
          profile: profile.name,
          region,
          accountId: profile.sso_account_id || identity.account,
          roleName: profile.sso_role_name || '',
          ssoSession: profile.sso_session,
          valid: true,
          identity,
        };
      } catch (err: any) {
        return {
          profile: profile.name,
          region,
          accountId: profile.sso_account_id || '',
          roleName: profile.sso_role_name || '',
          ssoSession: profile.sso_session,
          valid: false,
          error: err.message || 'Unknown error',
        };
      }
    })
  );

  return results.map((result) => {
    if (result.status === 'fulfilled') return result.value;
    return {
      profile: 'unknown',
      region: config.aws.defaultRegion,
      accountId: '',
      roleName: '',
      valid: false,
      error: 'Promise rejected',
    };
  });
}
