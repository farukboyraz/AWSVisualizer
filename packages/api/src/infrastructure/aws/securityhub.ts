import {
  SecurityHubClient,
  DescribeHubCommand,
  GetEnabledStandardsCommand,
  DescribeStandardsCommand,
  DescribeStandardsControlsCommand,
  GetFindingsCommand,
  ListEnabledProductsForImportCommand,
  ListMembersCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-securityhub';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, isNotEnabled, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new SecurityHubClient({ region: r, credentials: cachedCredentials(p) });

const FINDING_LIMIT = 100;

/** Security Hub answers InvalidAccessException when it isn't enabled in the region. */
const notEnabled = (err: unknown) => isNotEnabled(err) || (err as { name?: string })?.name === 'InvalidAccessException';

async function standardNames(c: SecurityHubClient): Promise<Map<string, string>> {
  const all = await pageAll((NextToken) => c.send(new DescribeStandardsCommand({ NextToken })), (r) => r.Standards, (r) => r.NextToken).catch(() => []);
  return new Map(all.map((s) => [s.StandardsArn || '', s.Name || '']));
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  let hub;
  try {
    hub = await c.send(new DescribeHubCommand({}));
  } catch (err) {
    if (notEnabled(err)) return [];
    throw err;
  }
  const [subs, names] = await Promise.all([pageAll((NextToken) => c.send(new GetEnabledStandardsCommand({ NextToken })), (r) => r.StandardsSubscriptions, (r) => r.NextToken), standardNames(c)]);
  return [
    { id: 'hub:', name: 'Security Hub', status: 'ENABLED', info: `Enabled ${hub.SubscribedAt?.slice(0, 10) ?? ''}` },
    { id: 'findings:', name: 'Active findings', info: `Highest severity first · first ${FINDING_LIMIT}` },
    ...subs.map((s) => ({ id: `std:${s.StandardsSubscriptionArn}`, name: names.get(s.StandardsArn || '') || lastPart(s.StandardsArn) || '', group: 'Security standards', status: s.StandardsStatus, info: s.StandardsArn })),
  ];
}

async function hubPage(c: SecurityHubClient, id: string): Promise<ResourcePage> {
  const hub = await c.send(new DescribeHubCommand({}));
  const errors: string[] = [];
  const parts = await settle(
    {
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: hub.HubArn })),
      products: pageAll((NextToken) => c.send(new ListEnabledProductsForImportCommand({ NextToken })), (r) => r.ProductSubscriptions, (r) => r.NextToken),
      members: pageAll((NextToken) => c.send(new ListMembersCommand({ NextToken, OnlyAssociated: false })), (r) => r.Members, (r) => r.NextToken),
    },
    errors,
  );
  return {
    id,
    title: 'Security Hub',
    subtitle: 'Hub settings',
    status: 'ENABLED',
    arn: hub.HubArn,
    tabs: [
      tab('Settings', {
        sections: [
          section('Hub', [
            ['Hub ARN', hub.HubArn],
            ['Enabled', hub.SubscribedAt],
            ['Auto-enable new controls', hub.AutoEnableControls],
            ['Consolidated control findings', hub.ControlFindingGenerator === 'SECURITY_CONTROL' ? 'On' : hub.ControlFindingGenerator === 'STANDARD_CONTROL' ? 'Off' : hub.ControlFindingGenerator],
          ]),
        ],
      }),
      tab('Integrations', {
        tables: [table(['Product subscription'], (parts.products || []).map((p) => [p]), { emptyMessage: 'No integrations accepting findings' })],
      }),
      tab('Accounts', {
        tables: [table(['Account', 'Email', 'Status', 'Administrator', 'Invited', 'Updated'], (parts.members || []).map((m) => [m.AccountId, m.Email, m.MemberStatus, m.AdministratorId, m.InvitedAt, m.UpdatedAt]), { statusColumn: 2, emptyMessage: 'No member accounts' })],
      }),
    ],
    tags: tagMap(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function findingsPage(c: SecurityHubClient, id: string): Promise<ResourcePage> {
  const res = await c.send(
    new GetFindingsCommand({
      Filters: {
        RecordState: [{ Value: 'ACTIVE', Comparison: 'EQUALS' }],
        WorkflowStatus: [
          { Value: 'NEW', Comparison: 'EQUALS' },
          { Value: 'NOTIFIED', Comparison: 'EQUALS' },
        ],
        ComplianceStatus: [{ Value: 'PASSED', Comparison: 'NOT_EQUALS' }],
      },
      SortCriteria: [{ Field: 'SeverityNormalized', SortOrder: 'desc' }],
      MaxResults: FINDING_LIMIT,
    }),
  );
  const findings = res.Findings || [];
  return {
    id,
    title: 'Active findings',
    subtitle: res.NextToken ? `Highest severity first · first ${FINDING_LIMIT}` : `${findings.length} active findings`,
    tabs: [
      tab('Findings', {
        tables: [
          table(
            ['Severity', 'Title', 'Product', 'Resource type', 'Resource', 'Compliance', 'Workflow', 'Updated'],
            findings.map((f) => [f.Severity?.Label, f.Title, f.ProductName, f.Resources?.[0]?.Type, f.Resources?.[0]?.Id, f.Compliance?.Status, f.Workflow?.Status, f.UpdatedAt]),
            { statusColumn: 0, emptyMessage: 'No active findings' },
          ),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function standardPage(c: SecurityHubClient, id: string, subArn: string): Promise<ResourcePage> {
  const sub = (await c.send(new GetEnabledStandardsCommand({ StandardsSubscriptionArns: [subArn] }))).StandardsSubscriptions?.[0];
  if (!sub) throw httpError(`Standard subscription not found: ${subArn}`, 404);
  const errors: string[] = [];
  const [names, controls] = await Promise.all([
    standardNames(c),
    pageAll((NextToken) => c.send(new DescribeStandardsControlsCommand({ StandardsSubscriptionArn: subArn, NextToken, MaxResults: 100 })), (r) => r.Controls, (r) => r.NextToken).catch((err) => (errors.push(`Controls: ${err.message}`), [])),
  ]);
  const enabled = controls.filter((x) => x.ControlStatus === 'ENABLED').length;
  return {
    id,
    title: names.get(sub.StandardsArn || '') || lastPart(sub.StandardsArn) || subArn,
    subtitle: `${enabled} of ${controls.length} controls enabled`,
    status: sub.StandardsStatus,
    arn: subArn,
    tabs: [
      tab('Controls', {
        tables: [
          table(
            ['Control', 'Title', 'Severity', 'Status', 'Disabled reason'],
            controls.map((x) => [x.ControlId, x.Title, x.SeverityRating, x.ControlStatus, x.DisabledReason]).sort((a, b) => String(a[0]).localeCompare(String(b[0]), undefined, { numeric: true })),
            { statusColumn: 3, emptyMessage: 'No controls' },
          ),
        ],
      }),
      tab('Details', {
        sections: [section('Subscription', [['Standard ARN', sub.StandardsArn], ['Subscription ARN', subArn], ['Status', sub.StandardsStatus], ['Status reason', sub.StandardsStatusReason?.StatusReasonCode]])],
      }),
    ],
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'hub') return hubPage(c, id);
  if (kind === 'findings') return findingsPage(c, id);
  if (kind === 'std') return standardPage(c, id, rest);
  throw httpError(`Unknown Security Hub page: ${id}`, 400);
}

export const securityHubAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  uncounted: true,
};
