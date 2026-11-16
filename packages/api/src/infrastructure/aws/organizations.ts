import {
  OrganizationsClient,
  DescribeOrganizationCommand,
  ListRootsCommand,
  ListAccountsCommand,
  DescribeAccountCommand,
  ListOrganizationalUnitsForParentCommand,
  DescribeOrganizationalUnitCommand,
  ListAccountsForParentCommand,
  ListParentsCommand,
  ListPoliciesCommand,
  DescribePolicyCommand,
  ListPoliciesForTargetCommand,
  ListTargetsForPolicyCommand,
  ListDelegatedAdministratorsCommand,
  ListAWSServiceAccessForOrganizationCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type PolicyType,
  type OrganizationalUnit,
  type PolicySummary,
} from '@aws-sdk/client-organizations';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, policyJson } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Organizations is global; its endpoint lives in us-east-1. */
const client = (p: string) => new OrganizationsClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

const POLICY_TYPES: PolicyType[] = ['SERVICE_CONTROL_POLICY', 'TAG_POLICY', 'BACKUP_POLICY', 'AISERVICES_OPT_OUT_POLICY'];
const POLICY_LABEL: Record<string, string> = { SERVICE_CONTROL_POLICY: 'SCP', TAG_POLICY: 'Tag policy', BACKUP_POLICY: 'Backup policy', AISERVICES_OPT_OUT_POLICY: 'AI opt-out policy' };
/** OU tree walk stops here so a huge org doesn't stall the list. */
const OU_LIMIT = 500;

const errName = (err: unknown) => (err as { name?: string })?.name;
const notInOrg = (err: unknown) => errName(err) === 'AWSOrganizationsNotInUseException';
/** Member accounts can describe the org but not list it. */
const memberOnly = (err: unknown) => errName(err) === 'AccessDeniedException';

async function walkOus(c: OrganizationsClient, rootId: string): Promise<(OrganizationalUnit & { path: string })[]> {
  const out: (OrganizationalUnit & { path: string })[] = [];
  const queue: { id: string; path: string }[] = [{ id: rootId, path: '' }];
  while (queue.length && out.length < OU_LIMIT) {
    const parent = queue.shift()!;
    const kids = await pageAll((NextToken) => c.send(new ListOrganizationalUnitsForParentCommand({ ParentId: parent.id, NextToken })), (r) => r.OrganizationalUnits, (r) => r.NextToken);
    for (const k of kids) {
      const path = `${parent.path}/${k.Name}`;
      out.push({ ...k, path });
      queue.push({ id: k.Id || '', path });
    }
  }
  return out;
}

type TypedPolicy = PolicySummary & { type: PolicyType };

/** Every policy of every type (org-wide, or attached to `targetId`); types that aren't enabled list nothing. */
async function allPolicies(c: OrganizationsClient, targetId?: string): Promise<TypedPolicy[]> {
  const perType = await Promise.all(
    POLICY_TYPES.map((Filter) =>
      pageAll(
        (NextToken) => (targetId ? c.send(new ListPoliciesForTargetCommand({ TargetId: targetId, Filter, NextToken })) : c.send(new ListPoliciesCommand({ Filter, NextToken }))),
        (r) => r.Policies,
        (r) => r.NextToken,
      )
        .then((ps) => ps.map((p) => ({ ...p, type: Filter })))
        .catch((): TypedPolicy[] => []),
    ),
  );
  return perType.flat();
}

async function list(profile: string): Promise<PageSummary[]> {
  const c = client(profile);
  let org;
  try {
    org = (await c.send(new DescribeOrganizationCommand({}))).Organization;
  } catch (err) {
    if (notInOrg(err)) return [];
    throw err;
  }
  const rows: PageSummary[] = [{ id: 'org:', name: org?.Id || 'Organization', group: 'Organization', info: `Management account ${org?.MasterAccountId ?? '-'} · ${org?.FeatureSet ?? ''}` }];
  try {
    const [accounts, roots] = await Promise.all([
      pageAll((NextToken) => c.send(new ListAccountsCommand({ NextToken })), (r) => r.Accounts, (r) => r.NextToken),
      c.send(new ListRootsCommand({})).then((r) => r.Roots || []),
    ]);
    const ous = roots[0]?.Id ? await walkOus(c, roots[0].Id) : [];
    const policies = await allPolicies(c);
    rows.push(
      ...accounts.map((a) => ({ id: `acct:${a.Id}`, name: a.Name || a.Id || '', group: 'Accounts', status: a.Status, info: [a.Id, a.Email, a.Id === org?.MasterAccountId && 'management account'].filter(Boolean).join(' · ') })).sort((a, b) => a.name.localeCompare(b.name)),
      ...roots.map((r) => ({ id: `ou:${r.Id}`, name: r.Name || 'Root', group: 'Organizational units', info: `Root · ${r.Id}` })),
      ...ous.sort((a, b) => a.path.localeCompare(b.path)).map((o) => ({ id: `ou:${o.Id}`, name: o.path, group: 'Organizational units', info: o.Id })),
      ...policies.map((p) => ({ id: `pol:${p.Id}`, name: p.Name || p.Id || '', group: 'Policies', info: [POLICY_LABEL[p.type], p.AwsManaged && 'AWS managed', p.Description].filter(Boolean).join(' · ') })).sort((a, b) => a.name.localeCompare(b.name)),
    );
  } catch (err) {
    if (!memberOnly(err)) throw err;
  }
  return rows;
}

async function orgPage(c: OrganizationsClient): Promise<ResourcePage> {
  const org = (await c.send(new DescribeOrganizationCommand({}))).Organization;
  const errors: string[] = [];
  const parts = await settle(
    {
      roots: c.send(new ListRootsCommand({})),
      admins: pageAll((NextToken) => c.send(new ListDelegatedAdministratorsCommand({ NextToken })), (r) => r.DelegatedAdministrators, (r) => r.NextToken),
      access: pageAll((NextToken) => c.send(new ListAWSServiceAccessForOrganizationCommand({ NextToken })), (r) => r.EnabledServicePrincipals, (r) => r.NextToken),
    },
    errors,
    memberOnly,
  );
  const root = parts.roots?.Roots?.[0];
  return {
    id: 'org:',
    title: org?.Id || 'Organization',
    subtitle: `Management account ${org?.MasterAccountId ?? '-'}`,
    arn: org?.Arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Organization', [
            ['Organization ID', org?.Id],
            ['Feature set', org?.FeatureSet],
            ['Management account', org?.MasterAccountId],
            ['Management account email', org?.MasterAccountEmail],
            ['Root', root?.Id],
          ]),
        ],
        tables: [table(['Policy type', 'Status'], (root?.PolicyTypes || []).map((p) => [POLICY_LABEL[p.Type || ''] ?? p.Type, p.Status]), { title: 'Policy types on the root', statusColumn: 1, emptyMessage: parts.roots ? 'No policy types enabled' : 'Only visible from the management account' })],
      }),
      tab('Trusted services', {
        tables: [table(['Service', 'Enabled'], (parts.access || []).map((s) => [s.ServicePrincipal, s.DateEnabled]), { emptyMessage: parts.access ? 'No trusted access enabled' : 'Only visible from the management account' })],
      }),
      tab('Delegated administrators', {
        tables: [table(['Account', 'Name', 'Email', 'Delegated'], (parts.admins || []).map((a) => [a.Id, a.Name, a.Email, a.DelegationEnabledDate]), { emptyMessage: parts.admins ? 'No delegated administrators' : 'Only visible from the management account' })],
      }),
    ],
    actions: [],
    errors,
  };
}

async function accountPage(c: OrganizationsClient, id: string, accountId: string): Promise<ResourcePage> {
  const a = (await c.send(new DescribeAccountCommand({ AccountId: accountId }))).Account;
  if (!a) throw httpError(`Account not found: ${accountId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      parents: c.send(new ListParentsCommand({ ChildId: accountId })),
      scps: pageAll((NextToken) => c.send(new ListPoliciesForTargetCommand({ TargetId: accountId, Filter: 'SERVICE_CONTROL_POLICY', NextToken })), (r) => r.Policies, (r) => r.NextToken),
      tags: pageAll((NextToken) => c.send(new ListTagsForResourceCommand({ ResourceId: accountId, NextToken })), (r) => r.Tags, (r) => r.NextToken),
    },
    errors,
  );
  return {
    id,
    title: a.Name || accountId,
    subtitle: `${accountId} · ${a.Email ?? ''}`,
    status: a.Status,
    arn: a.Arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Account', [
            ['Account ID', accountId],
            ['Name', a.Name],
            ['Email', a.Email],
            ['Status', a.Status],
            ['Joined by', a.JoinedMethod],
            ['Joined', a.JoinedTimestamp],
            ['Parent', (parts.parents?.Parents || []).map((p) => `${p.Type}: ${p.Id}`)],
          ]),
        ],
      }),
      tab('Policies', {
        tables: [table(['Policy', 'AWS managed', 'Description'], (parts.scps || []).map((p) => [p.Name, p.AwsManaged ? 'Yes' : 'No', p.Description]), { title: 'Directly attached SCPs', emptyMessage: 'No SCPs attached directly' })],
      }),
    ],
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function ouPage(c: OrganizationsClient, id: string, ouId: string): Promise<ResourcePage> {
  const isRoot = ouId.startsWith('r-');
  const ou = isRoot ? (await c.send(new ListRootsCommand({}))).Roots?.find((r) => r.Id === ouId) : (await c.send(new DescribeOrganizationalUnitCommand({ OrganizationalUnitId: ouId }))).OrganizationalUnit;
  if (!ou) throw httpError(`Organizational unit not found: ${ouId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      accounts: pageAll((NextToken) => c.send(new ListAccountsForParentCommand({ ParentId: ouId, NextToken })), (r) => r.Accounts, (r) => r.NextToken),
      children: pageAll((NextToken) => c.send(new ListOrganizationalUnitsForParentCommand({ ParentId: ouId, NextToken })), (r) => r.OrganizationalUnits, (r) => r.NextToken),
      policies: allPolicies(c, ouId),
      tags: pageAll((NextToken) => c.send(new ListTagsForResourceCommand({ ResourceId: ouId, NextToken })), (r) => r.Tags, (r) => r.NextToken),
    },
    errors,
  );
  return {
    id,
    title: ou.Name || ouId,
    subtitle: isRoot ? 'Organization root' : 'Organizational unit',
    arn: ou.Arn,
    tabs: [
      tab('Accounts', {
        tables: [table(['Account', 'ID', 'Email', 'Status'], (parts.accounts || []).map((a) => [a.Name, a.Id, a.Email, a.Status]), { statusColumn: 3, emptyMessage: 'No accounts directly in this OU' })],
      }),
      tab('Child OUs', {
        tables: [table(['OU', 'ID'], (parts.children || []).map((o) => [o.Name, o.Id]), { emptyMessage: 'No child OUs' })],
      }),
      tab('Policies', {
        tables: [table(['Policy', 'Type', 'AWS managed', 'Description'], (parts.policies || []).map((p) => [p.Name, POLICY_LABEL[p.type], p.AwsManaged ? 'Yes' : 'No', p.Description]), { emptyMessage: 'No policies attached directly' })],
      }),
    ],
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function policyPage(c: OrganizationsClient, id: string, policyId: string): Promise<ResourcePage> {
  const p = (await c.send(new DescribePolicyCommand({ PolicyId: policyId }))).Policy;
  if (!p) throw httpError(`Policy not found: ${policyId}`, 404);
  const s = p.PolicySummary;
  const errors: string[] = [];
  const parts = await settle(
    {
      targets: pageAll((NextToken) => c.send(new ListTargetsForPolicyCommand({ PolicyId: policyId, NextToken })), (r) => r.Targets, (r) => r.NextToken),
      tags: s?.AwsManaged ? Promise.resolve(undefined) : pageAll((NextToken) => c.send(new ListTagsForResourceCommand({ ResourceId: policyId, NextToken })), (r) => r.Tags, (r) => r.NextToken),
    },
    errors,
  );
  return {
    id,
    title: s?.Name || policyId,
    subtitle: [POLICY_LABEL[s?.Type || ''] ?? s?.Type, s?.AwsManaged && 'AWS managed'].filter(Boolean).join(' · '),
    arn: s?.Arn,
    tabs: [
      tab('Details', {
        sections: [section('Policy', [['Policy ID', s?.Id], ['Name', s?.Name], ['Type', POLICY_LABEL[s?.Type || ''] ?? s?.Type], ['AWS managed', s?.AwsManaged], ['Description', s?.Description], ['Targets', parts.targets?.length]])],
        tables: [table(['Target', 'Type', 'ID'], (parts.targets || []).map((t) => [t.Name, t.Type, t.TargetId]), { title: 'Attached to', emptyMessage: 'Not attached' })],
      }),
      tab('Content', { json: policyJson(p.Content) }),
    ],
    tags: s?.AwsManaged ? undefined : tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const c = client(profile);
  const [kind, rest] = splitId(id);
  if (kind === 'org') return orgPage(c);
  if (kind === 'acct') return accountPage(c, id, rest);
  if (kind === 'ou') return ouPage(c, id, rest);
  if (kind === 'pol') return policyPage(c, id, rest);
  throw httpError(`Unknown Organizations page: ${id}`, 400);
}

function tagTarget(id: string) {
  const [kind, rest] = splitId(id);
  if (kind === 'org') throw httpError('Tag the root, an OU, an account or a policy instead', 400);
  return rest;
}

export const organizationsAdapter: PageServiceAdapter = {
  list: (profile) => list(profile),
  detail,
  async addTag(profile, _region, id, _arn, key, value) {
    await client(profile).send(new TagResourceCommand({ ResourceId: tagTarget(id), Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, _region, id, _arn, key) {
    await client(profile).send(new UntagResourceCommand({ ResourceId: tagTarget(id), TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('acct:'),
};
