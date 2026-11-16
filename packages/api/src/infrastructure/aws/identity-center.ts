import {
  SSOAdminClient,
  ListInstancesCommand,
  ListPermissionSetsCommand,
  DescribePermissionSetCommand,
  ListManagedPoliciesInPermissionSetCommand,
  ListCustomerManagedPolicyReferencesInPermissionSetCommand,
  GetInlinePolicyForPermissionSetCommand,
  GetPermissionsBoundaryForPermissionSetCommand,
  ListAccountsForProvisionedPermissionSetCommand,
  ListAccountAssignmentsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-sso-admin';
import { IdentitystoreClient, ListUsersCommand, ListGroupsCommand } from '@aws-sdk/client-identitystore';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, policyJson, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const admin = (p: string, r: string) => new SSOAdminClient({ region: r, credentials: cachedCredentials(p) });
const store = (p: string, r: string) => new IdentitystoreClient({ region: r, credentials: cachedCredentials(p) });

/** Users / groups shown on the instance page, and accounts checked for assignments on a permission set page. */
const DIRECTORY_LIMIT = 500;
const ACCOUNT_LIMIT = 25;

/** ISO-8601 durations like PT8H → "8 h". */
const duration = (d?: string) => {
  const m = d?.match(/^PT(?:(\d+)H)?(?:(\d+)M)?$/);
  return m ? [m[1] && `${m[1]} h`, m[2] && `${m[2]} min`].filter(Boolean).join(' ') : d;
};

async function instances(c: SSOAdminClient) {
  return pageAll((NextToken) => c.send(new ListInstancesCommand({ NextToken })), (r) => r.Instances, (r) => r.NextToken);
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = admin(profile, region);
  const inst = await instances(c);
  const rows: PageSummary[] = [];
  for (const i of inst) {
    rows.push({ id: `inst:${i.InstanceArn}`, name: i.Name || 'Identity Center instance', group: 'Instance', status: i.Status, info: [i.IdentityStoreId, i.OwnerAccountId && `account ${i.OwnerAccountId}`].filter(Boolean).join(' · ') });
    const sets = await pageAll((NextToken) => c.send(new ListPermissionSetsCommand({ InstanceArn: i.InstanceArn, NextToken })), (r) => r.PermissionSets, (r) => r.NextToken).catch(() => []);
    const described = await mapLimited(sets, 5, (arn) => c.send(new DescribePermissionSetCommand({ InstanceArn: i.InstanceArn, PermissionSetArn: arn })).then((r) => r.PermissionSet).catch(() => undefined));
    rows.push(
      ...sets
        .map((arn, n) => ({ id: `ps:${i.InstanceArn}|${arn}`, name: described[n]?.Name || arn.split('/').pop() || arn, group: 'Permission sets', info: [described[n]?.Description, `session ${duration(described[n]?.SessionDuration) ?? '-'}`].filter(Boolean).join(' · ') }))
        .sort((a, b) => a.name.localeCompare(b.name)),
    );
  }
  return rows;
}

async function directory(profile: string, region: string, storeId: string) {
  const s = store(profile, region);
  const [users, groups] = await Promise.all([
    pageAll((NextToken) => s.send(new ListUsersCommand({ IdentityStoreId: storeId, NextToken, MaxResults: 100 })), (r) => r.Users, (r) => r.NextToken, DIRECTORY_LIMIT),
    pageAll((NextToken) => s.send(new ListGroupsCommand({ IdentityStoreId: storeId, NextToken, MaxResults: 100 })), (r) => r.Groups, (r) => r.NextToken, DIRECTORY_LIMIT),
  ]);
  return { users, groups };
}

async function instancePage(profile: string, region: string, id: string, instanceArn: string): Promise<ResourcePage> {
  const i = (await instances(admin(profile, region))).find((x) => x.InstanceArn === instanceArn);
  if (!i) throw httpError(`Identity Center instance not found: ${instanceArn}`, 404);
  const errors: string[] = [];
  const { dir } = await settle({ dir: directory(profile, region, i.IdentityStoreId || '') }, errors);
  return {
    id,
    title: i.Name || 'IAM Identity Center',
    subtitle: i.IdentityStoreId,
    status: i.Status,
    arn: instanceArn,
    tabs: [
      tab('Settings', {
        sections: [
          section('Instance', [
            ['Instance ARN', instanceArn],
            ['Identity store ID', i.IdentityStoreId],
            ['Owner account', i.OwnerAccountId],
            ['Status', i.Status],
            ['Created', i.CreatedDate],
            ['AWS access portal', i.IdentityStoreId && `https://${i.IdentityStoreId}.awsapps.com/start`],
          ]),
        ],
      }),
      tab('Users', {
        tables: [
          table(
            ['User name', 'Display name', 'Primary email', 'User ID'],
            (dir?.users || []).map((u) => [u.UserName, u.DisplayName, (u.Emails || []).find((e) => e.Primary)?.Value ?? u.Emails?.[0]?.Value, u.UserId]),
            { title: (dir?.users.length ?? 0) >= DIRECTORY_LIMIT ? `First ${DIRECTORY_LIMIT} users` : undefined, emptyMessage: 'No users (or users come from an external identity provider without SCIM)' },
          ),
        ],
      }),
      tab('Groups', {
        tables: [table(['Group', 'Description', 'Group ID'], (dir?.groups || []).map((g) => [g.DisplayName, g.Description, g.GroupId]), { emptyMessage: 'No groups' })],
      }),
    ],
    actions: [],
    errors,
  };
}

async function permissionSetPage(profile: string, region: string, id: string, instanceArn: string, psArn: string): Promise<ResourcePage> {
  const c = admin(profile, region);
  const base = { InstanceArn: instanceArn, PermissionSetArn: psArn };
  const ps = (await c.send(new DescribePermissionSetCommand(base))).PermissionSet;
  if (!ps) throw httpError(`Permission set not found: ${psArn}`, 404);
  const errors: string[] = [];
  const storeId = (await instances(c)).find((x) => x.InstanceArn === instanceArn)?.IdentityStoreId;
  const parts = await settle(
    {
      managed: pageAll((NextToken) => c.send(new ListManagedPoliciesInPermissionSetCommand({ ...base, NextToken })), (r) => r.AttachedManagedPolicies, (r) => r.NextToken),
      customer: pageAll((NextToken) => c.send(new ListCustomerManagedPolicyReferencesInPermissionSetCommand({ ...base, NextToken })), (r) => r.CustomerManagedPolicyReferences, (r) => r.NextToken),
      inline: c.send(new GetInlinePolicyForPermissionSetCommand(base)),
      // No boundary is a ResourceNotFound, not an error.
      boundary: c.send(new GetPermissionsBoundaryForPermissionSetCommand(base)).catch((err) => (err?.name === 'ResourceNotFoundException' ? undefined : Promise.reject(err))),
      accounts: pageAll((NextToken) => c.send(new ListAccountsForProvisionedPermissionSetCommand({ ...base, NextToken })), (r) => r.AccountIds, (r) => r.NextToken),
      tags: pageAll((NextToken) => c.send(new ListTagsForResourceCommand({ InstanceArn: instanceArn, ResourceArn: psArn, NextToken })), (r) => r.Tags, (r) => r.NextToken),
      dir: storeId ? directory(profile, region, storeId) : Promise.resolve(undefined),
    },
    errors,
  );
  const accounts = (parts.accounts || []).slice(0, ACCOUNT_LIMIT);
  const assignments = await mapLimited(accounts, 5, (AccountId) =>
    pageAll((NextToken) => c.send(new ListAccountAssignmentsCommand({ ...base, AccountId, NextToken })), (r) => r.AccountAssignments, (r) => r.NextToken).catch((err) => (errors.push(`Assignments in ${AccountId}: ${err.message}`), [])),
  );
  const userNames = new Map((parts.dir?.users || []).map((u) => [u.UserId || '', u.UserName || '']));
  const groupNames = new Map((parts.dir?.groups || []).map((g) => [g.GroupId || '', g.DisplayName || '']));
  const principal = (type?: string, pid?: string) => (type === 'USER' ? userNames.get(pid || '') : groupNames.get(pid || '')) || pid;
  const b = parts.boundary?.PermissionsBoundary;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Permission set', [
          ['Name', ps.Name],
          ['Description', ps.Description],
          ['Session duration', duration(ps.SessionDuration)],
          ['Relay state', ps.RelayState],
          ['Created', ps.CreatedDate],
          ['Provisioned to accounts', parts.accounts?.length],
          ['Permissions boundary', b?.ManagedPolicyArn ?? (b?.CustomerManagedPolicyReference ? `${b.CustomerManagedPolicyReference.Path ?? '/'}${b.CustomerManagedPolicyReference.Name}` : undefined)],
        ]),
      ],
    }),
    tab('Permissions', {
      tables: [
        table(['Policy', 'Type', 'ARN / path'], [...(parts.managed || []).map((p) => [p.Name, 'AWS managed', p.Arn]), ...(parts.customer || []).map((p) => [p.Name, 'Customer managed (by name)', p.Path ?? '/'])], { title: 'Policies', emptyMessage: 'No managed policies' }),
      ],
    }),
    tab('Assignments', {
      tables: [
        table(
          ['Account', 'Principal', 'Type'],
          accounts.flatMap((acct, n) => assignments[n].map((a) => [acct, principal(a.PrincipalType, a.PrincipalId), a.PrincipalType])),
          { title: (parts.accounts?.length ?? 0) > ACCOUNT_LIMIT ? `First ${ACCOUNT_LIMIT} of ${parts.accounts?.length} accounts` : undefined, emptyMessage: 'Not assigned in any account' },
        ),
      ],
    }),
  ];
  const inline = policyJson(parts.inline?.InlinePolicy);
  if (inline) tabs.push(tab('Inline policy', { json: inline }));
  return { id, title: ps.Name || psArn, subtitle: ps.Description || 'Permission set', arn: psArn, tabs, tags: tagList(parts.tags), actions: [], errors };
}

const parsePs = (rest: string) => {
  const [instanceArn, psArn] = rest.split('|');
  if (!instanceArn || !psArn) throw httpError(`Bad permission set id: ${rest}`, 400);
  return { instanceArn, psArn };
};

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'inst') return instancePage(profile, region, id, rest);
  if (kind === 'ps') {
    const { instanceArn, psArn } = parsePs(rest);
    return permissionSetPage(profile, region, id, instanceArn, psArn);
  }
  throw httpError(`Unknown Identity Center page: ${id}`, 400);
}

export const identityCenterAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    if (!id.startsWith('ps:')) throw httpError('Only permission sets can be tagged here', 400);
    const { instanceArn, psArn } = parsePs(splitId(id)[1]);
    await admin(profile, region).send(new TagResourceCommand({ InstanceArn: instanceArn, ResourceArn: psArn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    if (!id.startsWith('ps:')) throw httpError('Only permission sets can be tagged here', 400);
    const { instanceArn, psArn } = parsePs(splitId(id)[1]);
    await admin(profile, region).send(new UntagResourceCommand({ InstanceArn: instanceArn, ResourceArn: psArn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('ps:'),
};
