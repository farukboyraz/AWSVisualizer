import {
  RDSClient,
  DescribeDBProxiesCommand,
  DescribeDBProxyEndpointsCommand,
  DescribeDBProxyTargetGroupsCommand,
  DescribeDBProxyTargetsCommand,
  ListTagsForResourceCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  type DBProxy,
} from '@aws-sdk/client-rds';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new RDSClient({ region: r, credentials: cachedCredentials(p) });

async function proxies(c: RDSClient, name?: string): Promise<DBProxy[]> {
  const out: DBProxy[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeDBProxiesCommand({ DBProxyName: name, Marker }));
    out.push(...(res.DBProxies || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  return (await proxies(client(profile, region)))
    .map((p) => ({ id: p.DBProxyName || '', name: p.DBProxyName || '', status: p.Status, info: [p.EngineFamily, p.RequireTLS ? 'TLS required' : undefined].filter(Boolean).join(' · ') }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, name: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const p = (await proxies(c, name))[0];
  if (!p) throw httpError(`Proxy not found: ${name}`, 404);
  const errors: string[] = [];
  const { endpoints, groups, targets, tags } = await settle(
    {
      endpoints: c.send(new DescribeDBProxyEndpointsCommand({ DBProxyName: name })),
      groups: c.send(new DescribeDBProxyTargetGroupsCommand({ DBProxyName: name })),
      targets: c.send(new DescribeDBProxyTargetsCommand({ DBProxyName: name })),
      tags: c.send(new ListTagsForResourceCommand({ ResourceName: p.DBProxyArn })),
    },
    errors,
  );
  return {
    id: name,
    title: name,
    subtitle: `RDS Proxy · ${p.EngineFamily}`,
    status: p.Status,
    arn: p.DBProxyArn,
    tabs: [
      tab('Proxy configuration', {
        sections: [
          section('Configuration', [
            ['Engine family', p.EngineFamily],
            ['Require TLS', p.RequireTLS],
            ['Idle client timeout', p.IdleClientTimeout !== undefined ? `${p.IdleClientTimeout} s` : undefined],
            ['Enhanced logging', p.DebugLogging],
            ['IAM role', p.RoleArn?.split('/').pop()],
            ['Created', p.CreatedDate],
            ['Updated', p.UpdatedDate],
          ]),
          section('Network', [['VPC', p.VpcId], ['Subnets', p.VpcSubnetIds], ['Security groups', p.VpcSecurityGroupIds]]),
        ],
        tables: [
          table(
            ['User', 'Auth scheme', 'IAM auth', 'Client auth', 'Secret'],
            (p.Auth || []).map((a) => [a.UserName ?? '(all users in secret)', a.AuthScheme, a.IAMAuth, a.ClientPasswordAuthType, a.SecretArn?.split(':').pop()]),
            { title: 'Authentication' },
          ),
        ],
      }),
      tab('Proxy endpoints', {
        tables: [
          table(
            ['Name', 'Endpoint', 'Target role', 'Status'],
            [
              ['default', p.Endpoint, 'READ_WRITE', p.Status],
              ...(endpoints?.DBProxyEndpoints || []).filter((e) => !e.IsDefault).map((e) => [e.DBProxyEndpointName, e.Endpoint, e.TargetRole, e.Status]),
            ],
            { statusColumn: 3 },
          ),
        ],
      }),
      tab('Target groups', {
        tables: [
          ...(groups?.TargetGroups || []).map((g) => {
            const pool = g.ConnectionPoolConfig;
            return table(['Setting', 'Value'], [
              ['Max connections', pool?.MaxConnectionsPercent !== undefined ? `${pool.MaxConnectionsPercent}%` : undefined],
              ['Max idle connections', pool?.MaxIdleConnectionsPercent !== undefined ? `${pool.MaxIdleConnectionsPercent}%` : undefined],
              ['Connection borrow timeout', pool?.ConnectionBorrowTimeout !== undefined ? `${pool.ConnectionBorrowTimeout} s` : undefined],
              ['Session pinning filters', pool?.SessionPinningFilters],
              ['Initialization query', pool?.InitQuery],
            ], { title: `${g.TargetGroupName}${g.IsDefault ? ' (default)' : ''} · ${g.Status}` });
          }),
          table(
            ['Target', 'Type', 'Role', 'Endpoint', 'Health', 'Reason'],
            (targets?.Targets || []).map((t) => [t.RdsResourceId ?? t.TrackedClusterId, t.Type, t.Role, t.Endpoint && `${t.Endpoint}:${t.Port}`, t.TargetHealth?.State, t.TargetHealth?.Description ?? t.TargetHealth?.Reason]),
            { title: 'Targets', statusColumn: 4, emptyMessage: 'No targets registered' },
          ),
        ],
      }),
    ],
    tags: tags ? tagList(tags.TagList) : undefined,
    actions: [],
    errors,
  };
}

export const rdsProxyAdapter: PageServiceAdapter = singleKind('proxy', {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new AddTagsToResourceCommand({ ResourceName: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new RemoveTagsFromResourceCommand({ ResourceName: arn, TagKeys: [key] }));
  },
});
