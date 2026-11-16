import {
  FMSClient,
  GetAdminAccountCommand,
  ListPoliciesCommand,
  GetPolicyCommand,
  ListComplianceStatusCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-fms';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, policyJson } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new FMSClient({ region: r, credentials: cachedCredentials(p) });

/** Firewall Manager only answers its administrator account; anything else gets these. */
const notAdmin = (err: unknown) => /InvalidOperation|ResourceNotFound|AccessDenied/.test((err as { name?: string })?.name || '');

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const admin = await c.send(new GetAdminAccountCommand({})).catch((err) => (notAdmin(err) ? undefined : Promise.reject(err)));
  const policies = await pageAll((NextToken) => c.send(new ListPoliciesCommand({ NextToken })), (r) => r.PolicyList, (r) => r.NextToken).catch((err) => (notAdmin(err) ? [] : Promise.reject(err)));
  return [
    { id: 'admin:', name: 'Administrator', status: admin?.RoleStatus, info: admin?.AdminAccount ? `Account ${admin.AdminAccount}` : 'No Firewall Manager administrator (or this account is not it)' },
    ...policies
      .map((p) => ({ id: `pol:${p.PolicyId}`, name: p.PolicyName || p.PolicyId || '', group: 'Security policies', status: p.PolicyStatus, info: [p.SecurityServiceType, p.ResourceType, p.RemediationEnabled ? 'auto remediation' : undefined].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function adminPage(c: FMSClient, id: string): Promise<ResourcePage> {
  const errors: string[] = [];
  const admin = await c.send(new GetAdminAccountCommand({})).catch((err) => {
    if (!notAdmin(err)) errors.push(`Administrator: ${err.message}`);
    return undefined;
  });
  return {
    id,
    title: 'Firewall Manager administrator',
    status: admin?.RoleStatus,
    tabs: [
      tab('Settings', {
        sections: [
          section('Administrator', [['Administrator account', admin?.AdminAccount ?? 'None'], ['Role status', admin?.RoleStatus]], {
            note: 'Firewall Manager needs AWS Organizations and a delegated administrator account. Policies are only visible from that account, in the region where they were created.',
          }),
        ],
      }),
    ],
    actions: [],
    errors,
  };
}

async function policyPage(c: FMSClient, id: string, policyId: string): Promise<ResourcePage> {
  const res = await c.send(new GetPolicyCommand({ PolicyId: policyId }));
  const p = res.Policy;
  if (!p) throw httpError(`Policy not found: ${policyId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      compliance: pageAll((NextToken) => c.send(new ListComplianceStatusCommand({ PolicyId: policyId, NextToken })), (r) => r.PolicyComplianceStatusList, (r) => r.NextToken),
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: res.PolicyArn })),
    },
    errors,
  );
  const scope = (m?: Record<string, string[]>) => Object.entries(m || {}).map(([k, v]) => `${k}: ${v.join(', ')}`);
  return {
    id,
    title: p.PolicyName || policyId,
    subtitle: p.PolicyDescription || p.SecurityServicePolicyData?.Type,
    status: p.PolicyStatus,
    arn: res.PolicyArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Policy', [
            ['Policy ID', p.PolicyId],
            ['Security service', p.SecurityServicePolicyData?.Type],
            ['Resource type', p.ResourceType],
            ['Resource types', p.ResourceTypeList],
            ['Automatic remediation', p.RemediationEnabled],
            ['Delete unused managed resources', p.DeleteUnusedFMManagedResources],
            ['Exclude resource tags', p.ExcludeResourceTags],
            ['Resource tags', (p.ResourceTags || []).map((t) => `${t.Key}=${t.Value ?? ''}`)],
            ['Include accounts / OUs', scope(p.IncludeMap)],
            ['Exclude accounts / OUs', scope(p.ExcludeMap)],
            ['Status', p.PolicyStatus],
          ]),
        ],
      }),
      tab('Account compliance', {
        tables: [
          table(
            ['Account', 'Compliance', 'Violations', 'Evaluation limit exceeded', 'Last updated'],
            (parts.compliance || []).map((s) => [
              s.MemberAccount,
              (s.EvaluationResults || []).every((e) => e.ComplianceStatus === 'COMPLIANT') ? 'COMPLIANT' : 'NON_COMPLIANT',
              (s.EvaluationResults || []).reduce((n, e) => n + (e.ViolatorCount ?? 0), 0),
              (s.EvaluationResults || []).some((e) => e.EvaluationLimitExceeded),
              s.LastUpdated,
            ]),
            { statusColumn: 1, emptyMessage: 'No accounts in scope yet' },
          ),
        ],
      }),
      tab('Policy rules (JSON)', { json: policyJson(p.SecurityServicePolicyData?.ManagedServiceData) ?? JSON.stringify(p.SecurityServicePolicyData, null, 2) }),
    ],
    tags: tagList(parts.tags?.TagList),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'admin') return adminPage(c, id);
  if (kind === 'pol') return policyPage(c, id, rest);
  throw httpError(`Unknown Firewall Manager page: ${id}`, 400);
}

export const firewallManagerAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, TagList: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('pol:'),
};
