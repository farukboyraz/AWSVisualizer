import {
  CodeStarConnectionsClient,
  ListConnectionsCommand,
  GetConnectionCommand,
  ListHostsCommand,
  GetHostCommand,
  ListTagsForResourceCommand as ListConnectionTagsCommand,
  TagResourceCommand as TagConnectionCommand,
  UntagResourceCommand as UntagConnectionCommand,
} from '@aws-sdk/client-codestar-connections';
import {
  CodestarNotificationsClient,
  ListNotificationRulesCommand,
  DescribeNotificationRuleCommand,
  TagResourceCommand as TagRuleCommand,
  UntagResourceCommand as UntagRuleCommand,
} from '@aws-sdk/client-codestar-notifications';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, tagList, tagMap, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/**
 * CodeStar projects were shut down in July 2024 (their SDK client is gone).
 * What's left and widely used: CodeStar Connections (GitHub / GitLab /
 * Bitbucket links for CodePipeline, CodeBuild…) with their hosts, and
 * CodeStar Notifications rules.
 */
const connections = (p: string, r: string) => new CodeStarConnectionsClient({ region: r, credentials: cachedCredentials(p) });
const notifications = (p: string, r: string) => new CodestarNotificationsClient({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = connections(profile, region);
  const n = notifications(profile, region);
  const [conns, hosts, rules] = await Promise.all([
    pageAll((NextToken) => c.send(new ListConnectionsCommand({ NextToken })), (r) => r.Connections, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListHostsCommand({ NextToken })), (r) => r.Hosts, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => n.send(new ListNotificationRulesCommand({ NextToken })), (r) => r.NotificationRules, (r) => r.NextToken).catch(() => []),
  ]);
  const described = await mapLimited(rules, 5, (r) => n.send(new DescribeNotificationRuleCommand({ Arn: r.Arn })).catch(() => undefined));
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...conns.map((x) => ({ id: `conn:${x.ConnectionArn}`, name: x.ConnectionName || '', group: 'Connections', status: x.ConnectionStatus, info: x.ProviderType })).sort(byName),
    ...hosts.map((h) => ({ id: `host:${h.HostArn}`, name: h.Name || '', group: 'Hosts', status: h.Status, info: [h.ProviderType, h.ProviderEndpoint].filter(Boolean).join(' · ') })).sort(byName),
    ...rules.map((r, i) => ({ id: `rule:${r.Arn}`, name: described[i]?.Name || lastPart(r.Arn) || '', group: 'Notification rules', status: described[i]?.Status, info: lastPart(described[i]?.Resource) })).sort(byName),
  ];
}

async function connectionPage(profile: string, region: string, id: string, arn: string): Promise<ResourcePage> {
  const c = connections(profile, region);
  const x = (await c.send(new GetConnectionCommand({ ConnectionArn: arn }))).Connection;
  if (!x) throw httpError(`Connection not found: ${arn}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListConnectionTagsCommand({ ResourceArn: arn })) }, errors);
  return {
    id,
    title: x.ConnectionName || arn,
    subtitle: `${x.ProviderType ?? ''} connection`,
    status: x.ConnectionStatus,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Connection', [['Name', x.ConnectionName], ['Provider', x.ProviderType], ['Status', x.ConnectionStatus], ['Owner account', x.OwnerAccountId], ['Host', x.HostArn]], {
            note: x.ConnectionStatus === 'PENDING' ? 'Pending connections are completed (authorized with the provider) in the console.' : undefined,
          }),
        ],
      }),
    ],
    tags: tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

async function hostPage(profile: string, region: string, id: string, arn: string): Promise<ResourcePage> {
  const c = connections(profile, region);
  const h = await c.send(new GetHostCommand({ HostArn: arn }));
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListConnectionTagsCommand({ ResourceArn: arn })) }, errors);
  const v = h.VpcConfiguration;
  return {
    id,
    title: h.Name || arn,
    subtitle: `${h.ProviderType ?? ''} host`,
    status: h.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [section('Host', [['Name', h.Name], ['Provider', h.ProviderType], ['Endpoint', h.ProviderEndpoint], ['Status', h.Status], ['VPC', v?.VpcId], ['Subnets', v?.SubnetIds], ['Security groups', v?.SecurityGroupIds], ['TLS certificate', v?.TlsCertificate ? 'Set' : undefined]])],
      }),
    ],
    tags: tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

async function rulePage(profile: string, region: string, id: string, arn: string): Promise<ResourcePage> {
  const r = await notifications(profile, region).send(new DescribeNotificationRuleCommand({ Arn: arn }));
  return {
    id,
    title: r.Name || arn,
    subtitle: 'Notification rule',
    status: r.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [section('Rule', [['Name', r.Name], ['Resource', r.Resource], ['Status', r.Status], ['Detail', r.DetailType], ['Created by', r.CreatedBy], ['Created', r.CreatedTimestamp], ['Modified', r.LastModifiedTimestamp]])],
        tables: [
          table(['Event', 'Service', 'Resource type'], (r.EventTypes || []).map((e) => [e.EventTypeName, e.ServiceName, e.ResourceType]), { title: 'Events', emptyMessage: 'No events' }),
          table(['Target', 'Type', 'Status'], (r.Targets || []).map((t) => [t.TargetAddress, t.TargetType, t.TargetStatus]), { title: 'Targets', statusColumn: 2, emptyMessage: 'No targets' }),
        ],
      }),
    ],
    tags: tagMap(r.Tags),
    actions: [],
    errors: [],
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, arn] = splitId(id);
  if (kind === 'conn') return connectionPage(profile, region, id, arn);
  if (kind === 'host') return hostPage(profile, region, id, arn);
  if (kind === 'rule') return rulePage(profile, region, id, arn);
  throw httpError(`Unknown CodeStar page: ${id}`, 400);
}

export const codeStarAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    const [kind, arn] = splitId(id);
    if (kind === 'rule') await notifications(profile, region).send(new TagRuleCommand({ Arn: arn, Tags: { [key]: value } }));
    else if (kind === 'conn' || kind === 'host') await connections(profile, region).send(new TagConnectionCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
    else throw httpError(`Unknown CodeStar resource: ${id}`, 400);
  },
  async removeTag(profile, region, id, _arn, key) {
    const [kind, arn] = splitId(id);
    if (kind === 'rule') await notifications(profile, region).send(new UntagRuleCommand({ Arn: arn, TagKeys: [key] }));
    else if (kind === 'conn' || kind === 'host') await connections(profile, region).send(new UntagConnectionCommand({ ResourceArn: arn, TagKeys: [key] }));
    else throw httpError(`Unknown CodeStar resource: ${id}`, 400);
  },
  countable: (row) => row.id.startsWith('conn:'),
};
