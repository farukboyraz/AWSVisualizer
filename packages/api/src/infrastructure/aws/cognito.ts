import {
  CognitoIdentityProviderClient,
  ListUserPoolsCommand,
  DescribeUserPoolCommand,
  ListUserPoolClientsCommand,
  DescribeUserPoolClientCommand,
  ListUsersCommand,
  ListGroupsCommand,
  ListIdentityProvidersCommand,
  GetUserPoolMfaConfigCommand,
  TagResourceCommand as TagUserPoolCommand,
  UntagResourceCommand as UntagUserPoolCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import {
  CognitoIdentityClient,
  ListIdentityPoolsCommand,
  DescribeIdentityPoolCommand,
  GetIdentityPoolRolesCommand,
  TagResourceCommand as TagIdentityPoolCommand,
  UntagResourceCommand as UntagIdentityPoolCommand,
} from '@aws-sdk/client-cognito-identity';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, tagMap, accountId } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const idp = (p: string, r: string) => new CognitoIdentityProviderClient({ region: r, credentials: cachedCredentials(p) });
const identity = (p: string, r: string) => new CognitoIdentityClient({ region: r, credentials: cachedCredentials(p) });

/** Users shown on a user pool page (one ListUsers page; the console pages too). */
const USER_LIMIT = 60;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const [pools, idPools] = await Promise.all([
    pageAll((NextToken) => idp(profile, region).send(new ListUserPoolsCommand({ MaxResults: 60, NextToken })), (r) => r.UserPools, (r) => r.NextToken),
    pageAll((NextToken) => identity(profile, region).send(new ListIdentityPoolsCommand({ MaxResults: 60, NextToken })), (r) => r.IdentityPools, (r) => r.NextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...pools.map((p) => ({ id: `up:${p.Id}`, name: p.Name || p.Id || '', group: 'User pools', status: p.Status, info: [p.Id, p.LastModifiedDate && `modified ${p.LastModifiedDate.toISOString().slice(0, 10)}`].filter(Boolean).join(' · ') })).sort(byName),
    ...idPools.map((p) => ({ id: `ip:${p.IdentityPoolId}`, name: p.IdentityPoolName || p.IdentityPoolId || '', group: 'Identity pools', info: p.IdentityPoolId })).sort(byName),
  ];
}

async function userPoolPage(profile: string, region: string, id: string, poolId: string): Promise<ResourcePage> {
  const c = idp(profile, region);
  const p = (await c.send(new DescribeUserPoolCommand({ UserPoolId: poolId }))).UserPool;
  if (!p) throw httpError(`User pool not found: ${poolId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      clients: pageAll((NextToken) => c.send(new ListUserPoolClientsCommand({ UserPoolId: poolId, MaxResults: 60, NextToken })), (r) => r.UserPoolClients, (r) => r.NextToken),
      users: c.send(new ListUsersCommand({ UserPoolId: poolId, Limit: USER_LIMIT })),
      groups: pageAll((NextToken) => c.send(new ListGroupsCommand({ UserPoolId: poolId, NextToken })), (r) => r.Groups, (r) => r.NextToken),
      providers: pageAll((NextToken) => c.send(new ListIdentityProvidersCommand({ UserPoolId: poolId, NextToken })), (r) => r.Providers, (r) => r.NextToken),
      mfa: c.send(new GetUserPoolMfaConfigCommand({ UserPoolId: poolId })),
    },
    errors,
  );
  // Per-client settings. DescribeUserPoolClient also returns the client
  // secret - only the fields below are read, the secret is never passed on.
  const clients = await mapLimited(parts.clients || [], 5, (cl) =>
    c
      .send(new DescribeUserPoolClientCommand({ UserPoolId: poolId, ClientId: cl.ClientId }))
      .then((r) => r.UserPoolClient)
      .catch(() => undefined),
  );
  const pw = p.Policies?.PasswordPolicy;
  const triggers = Object.entries(p.LambdaConfig || {}).filter(([, v]) => typeof v === 'string');
  const attr = (u: { Attributes?: { Name?: string; Value?: string }[] }, n: string) => u.Attributes?.find((a) => a.Name === n)?.Value;
  return {
    id,
    title: p.Name || poolId,
    subtitle: `User pool · ${poolId}`,
    status: p.Status,
    arn: p.Arn,
    tabs: [
      tab('Overview', {
        sections: [
          section('User pool', [
            ['User pool ID', p.Id],
            ['Estimated users', p.EstimatedNumberOfUsers],
            ['Created', p.CreationDate],
            ['Last modified', p.LastModifiedDate],
            ['Deletion protection', p.DeletionProtection],
            ['Domain', p.CustomDomain || p.Domain],
            ['User pool tier', (p as { UserPoolTier?: string }).UserPoolTier],
          ]),
          section('Sign-in', [
            ['Username attributes', p.UsernameAttributes],
            ['Alias attributes', p.AliasAttributes],
            ['Case sensitive usernames', p.UsernameConfiguration?.CaseSensitive],
            ['Auto-verified attributes', p.AutoVerifiedAttributes],
            ['Self sign-up', p.AdminCreateUserConfig?.AllowAdminCreateUserOnly === undefined ? undefined : !p.AdminCreateUserConfig.AllowAdminCreateUserOnly],
            ['MFA', parts.mfa?.MfaConfiguration ?? p.MfaConfiguration],
            ['Software token MFA', parts.mfa?.SoftwareTokenMfaConfiguration?.Enabled],
            ['SMS MFA', parts.mfa?.SmsMfaConfiguration ? 'Configured' : undefined],
            ['Advanced security', p.UserPoolAddOns?.AdvancedSecurityMode],
          ]),
          section('Password policy', [
            ['Minimum length', pw?.MinimumLength],
            ['Requires uppercase', pw?.RequireUppercase],
            ['Requires lowercase', pw?.RequireLowercase],
            ['Requires numbers', pw?.RequireNumbers],
            ['Requires symbols', pw?.RequireSymbols],
            ['Temporary password validity', pw?.TemporaryPasswordValidityDays !== undefined ? `${pw.TemporaryPasswordValidityDays} days` : undefined],
          ]),
          section('Messaging', [
            ['Email sending', p.EmailConfiguration?.EmailSendingAccount],
            ['From address', p.EmailConfiguration?.From ?? p.EmailConfiguration?.SourceArn],
            ['SMS role', p.SmsConfiguration?.SnsCallerArn],
          ]),
        ],
      }),
      tab('Users', {
        tables: [
          table(
            ['Username', 'Email', 'Status', 'Enabled', 'Created', 'Modified'],
            (parts.users?.Users || []).map((u) => [u.Username, attr(u, 'email'), u.UserStatus, u.Enabled, u.UserCreateDate, u.UserLastModifiedDate]),
            { title: parts.users?.PaginationToken ? `First ${USER_LIMIT} users` : undefined, statusColumn: 2, emptyMessage: 'No users' },
          ),
        ],
      }),
      tab('Groups', {
        tables: [table(['Group', 'Description', 'Precedence', 'IAM role', 'Created'], (parts.groups || []).map((g) => [g.GroupName, g.Description, g.Precedence, g.RoleArn, g.CreationDate]), { emptyMessage: 'No groups' })],
      }),
      tab('App clients', {
        tables: [
          table(
            ['App client', 'Client ID', 'Client secret', 'Auth flows', 'OAuth flows', 'Callback URLs', 'Token validity (access / id / refresh)'],
            (parts.clients || []).map((cl, i) => {
              const d = clients[i];
              const unit = d?.TokenValidityUnits;
              return [
                cl.ClientName,
                cl.ClientId,
                d ? (d.ClientSecret ? 'Yes' : 'No') : '-',
                d?.ExplicitAuthFlows,
                d?.AllowedOAuthFlows,
                d?.CallbackURLs,
                d ? `${d.AccessTokenValidity ?? 60} ${unit?.AccessToken ?? 'minutes'} / ${d.IdTokenValidity ?? 60} ${unit?.IdToken ?? 'minutes'} / ${d.RefreshTokenValidity ?? 30} ${unit?.RefreshToken ?? 'days'}` : '-',
              ];
            }),
            { emptyMessage: 'No app clients' },
          ),
        ],
      }),
      tab('Sign-in experience', {
        tables: [
          table(['Identity provider', 'Type', 'Created'], (parts.providers || []).map((x) => [x.ProviderName, x.ProviderType, x.CreationDate]), { title: 'Federated identity providers', emptyMessage: 'Only Cognito user pool sign-in' }),
          table(['Trigger', 'Lambda function'], triggers.map(([k, v]) => [k, v]), { title: 'Lambda triggers', emptyMessage: 'No Lambda triggers' }),
        ],
      }),
    ],
    tags: tagMap(p.UserPoolTags),
    actions: [],
    errors,
  };
}

async function identityPoolPage(profile: string, region: string, id: string, poolId: string): Promise<ResourcePage> {
  const c = identity(profile, region);
  const p = await c.send(new DescribeIdentityPoolCommand({ IdentityPoolId: poolId }));
  const errors: string[] = [];
  const { roles, account } = await settle({ roles: c.send(new GetIdentityPoolRolesCommand({ IdentityPoolId: poolId })), account: accountId(profile, region) }, errors);
  return {
    id,
    title: p.IdentityPoolName || poolId,
    subtitle: `Identity pool · ${poolId}`,
    arn: account ? `arn:aws:cognito-identity:${region}:${account}:identitypool/${poolId}` : undefined,
    tabs: [
      tab('Overview', {
        sections: [
          section('Identity pool', [
            ['Identity pool ID', poolId],
            ['Guest (unauthenticated) access', p.AllowUnauthenticatedIdentities],
            ['Basic (classic) flow', p.AllowClassicFlow],
            ['Developer provider name', p.DeveloperProviderName],
            ['Authenticated role', roles?.Roles?.authenticated],
            ['Guest role', roles?.Roles?.unauthenticated],
          ]),
        ],
      }),
      tab('Identity providers', {
        tables: [
          table(
            ['Provider', 'Type', 'Client / app ID', 'Role selection'],
            [
              ...(p.CognitoIdentityProviders || []).map((x) => [x.ProviderName, 'Cognito user pool', x.ClientId, roles?.RoleMappings?.[`${x.ProviderName}:${x.ClientId}`]?.Type ?? 'Default role']),
              ...Object.entries(p.SupportedLoginProviders || {}).map(([k, v]) => [k, 'Social', v, roles?.RoleMappings?.[k]?.Type ?? 'Default role']),
              ...(p.OpenIdConnectProviderARNs || []).map((a) => [a, 'OpenID Connect', '-', roles?.RoleMappings?.[a]?.Type ?? 'Default role']),
              ...(p.SamlProviderARNs || []).map((a) => [a, 'SAML', '-', roles?.RoleMappings?.[a]?.Type ?? 'Default role']),
            ],
            { emptyMessage: 'No identity providers' },
          ),
        ],
      }),
    ],
    tags: tagMap(p.IdentityPoolTags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'up') return userPoolPage(profile, region, id, rest);
  if (kind === 'ip') return identityPoolPage(profile, region, id, rest);
  throw httpError(`Unknown Cognito resource: ${id}`, 400);
}

export const cognitoAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (id.startsWith('ip:')) await identity(profile, region).send(new TagIdentityPoolCommand({ ResourceArn: arn, Tags: { [key]: value } }));
    else await idp(profile, region).send(new TagUserPoolCommand({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (id.startsWith('ip:')) await identity(profile, region).send(new UntagIdentityPoolCommand({ ResourceArn: arn, TagKeys: [key] }));
    else await idp(profile, region).send(new UntagUserPoolCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
};
