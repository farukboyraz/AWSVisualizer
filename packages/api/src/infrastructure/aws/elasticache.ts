import {
  ElastiCacheClient,
  DescribeReplicationGroupsCommand,
  DescribeCacheClustersCommand,
  DescribeServerlessCachesCommand,
  DescribeSnapshotsCommand,
  DescribeServerlessCacheSnapshotsCommand,
  DescribeEventsCommand,
  ListTagsForResourceCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  type CacheCluster,
  type ReplicationGroup,
  type ServerlessCache,
  type SourceType,
} from '@aws-sdk/client-elasticache';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, endpointText, httpError, EVENT_WINDOW_MINUTES } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

function client(profile: string, region: string) {
  return new ElastiCacheClient({ region, credentials: cachedCredentials(profile) });
}

async function allReplicationGroups(c: ElastiCacheClient, id?: string): Promise<ReplicationGroup[]> {
  const out: ReplicationGroup[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeReplicationGroupsCommand({ ReplicationGroupId: id, Marker }));
    out.push(...(res.ReplicationGroups || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

async function allCacheClusters(c: ElastiCacheClient, id?: string, nodes = false): Promise<CacheCluster[]> {
  const out: CacheCluster[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeCacheClustersCommand({ CacheClusterId: id, Marker, ShowCacheNodeInfo: nodes }));
    out.push(...(res.CacheClusters || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

async function allServerless(c: ElastiCacheClient, name?: string): Promise<ServerlessCache[]> {
  const out: ServerlessCache[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new DescribeServerlessCachesCommand({ ServerlessCacheName: name, NextToken }));
    out.push(...(res.ServerlessCaches || []));
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

const engineName = (e?: string) => (e === 'redis' ? 'Redis OSS' : e === 'valkey' ? 'Valkey' : e === 'memcached' ? 'Memcached' : e);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [rgs, ccs, sls] = await Promise.all([
    allReplicationGroups(c),
    allCacheClusters(c),
    allServerless(c).catch(() => [] as ServerlessCache[]),
  ]);
  const byId = new Map(ccs.map((cc) => [cc.CacheClusterId, cc]));
  const out: PageSummary[] = [];
  for (const rg of rgs) {
    const member = byId.get(rg.MemberClusters?.[0]);
    out.push({
      id: `rg:${rg.ReplicationGroupId}`,
      name: rg.ReplicationGroupId || '',
      group: 'Clusters',
      status: rg.Status,
      info: [engineName(member?.Engine), member?.EngineVersion, rg.CacheNodeType, `${rg.NodeGroups?.length ?? 0} shards`].filter(Boolean).join(' · '),
    });
  }
  for (const cc of ccs.filter((x) => !x.ReplicationGroupId)) {
    out.push({
      id: `cc:${cc.CacheClusterId}`,
      name: cc.CacheClusterId || '',
      group: 'Clusters',
      status: cc.CacheClusterStatus,
      info: [engineName(cc.Engine), cc.EngineVersion, cc.CacheNodeType, `${cc.NumCacheNodes ?? 0} nodes`].filter(Boolean).join(' · '),
    });
  }
  for (const s of sls) {
    out.push({
      id: `sl:${s.ServerlessCacheName}`,
      name: s.ServerlessCacheName || '',
      group: 'Serverless caches',
      status: s.Status,
      info: [engineName(s.Engine), s.FullEngineVersion ?? s.MajorEngineVersion].filter(Boolean).join(' · '),
    });
  }
  return out.sort((a, b) => (a.group || '').localeCompare(b.group || '') || a.name.localeCompare(b.name));
}

async function eventsTab(c: ElastiCacheClient, type: SourceType, id: string, errors: string[]): Promise<PageTab> {
  const { events } = await settle({ events: c.send(new DescribeEventsCommand({ SourceType: type, SourceIdentifier: id, Duration: EVENT_WINDOW_MINUTES })) }, errors);
  return tab('Events', {
    tables: [table(['Date', 'Message'], (events?.Events || []).map((e) => [e.Date, e.Message]), { emptyMessage: 'No events in the last 7 days' })],
  });
}

function securitySection(cc?: CacheCluster, extra: [string, unknown][] = []) {
  return section('Network and security', [
    ['Subnet group', cc?.CacheSubnetGroupName],
    ['Security groups', (cc?.SecurityGroups || []).map((g) => `${g.SecurityGroupId} (${g.Status})`)],
    ['Network type', cc?.NetworkType],
    ['IP discovery', cc?.IpDiscovery],
    ['Encryption in transit', cc?.TransitEncryptionEnabled],
    ['Encryption at rest', cc?.AtRestEncryptionEnabled],
    ['AUTH token', cc?.AuthTokenEnabled],
    ...extra,
  ]);
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  const errors: string[] = [];

  if (kind === 'rg') {
    const rg = (await allReplicationGroups(c, name))[0];
    if (!rg) throw httpError(`Replication group not found: ${name}`, 404);
    const { members, snaps, tags } = await settle(
      {
        members: Promise.all((rg.MemberClusters || []).map((m) => allCacheClusters(c, m, true).then((r) => r[0]))),
        snaps: c.send(new DescribeSnapshotsCommand({ ReplicationGroupId: name })),
        tags: rg.ARN ? c.send(new ListTagsForResourceCommand({ ResourceName: rg.ARN })) : Promise.resolve(undefined),
      },
      errors,
    );
    const first = members?.[0];
    const memberById = new Map((members || []).map((m) => [m?.CacheClusterId, m]));
    const endpoints = [
      ['Configuration endpoint', endpointText(rg.ConfigurationEndpoint)],
      ...(rg.NodeGroups || []).flatMap((g) => [
        [`Primary endpoint${(rg.NodeGroups?.length ?? 0) > 1 ? ` (${g.NodeGroupId})` : ''}`, endpointText(g.PrimaryEndpoint)],
        [`Reader endpoint${(rg.NodeGroups?.length ?? 0) > 1 ? ` (${g.NodeGroupId})` : ''}`, endpointText(g.ReaderEndpoint)],
      ]),
    ].filter(([, v]) => v).map(([label, value]) => ({ label: label as string, value: value as string }));

    return {
      id,
      title: name,
      subtitle: rg.Description,
      status: rg.Status,
      arn: rg.ARN,
      tabs: [
        tab('Cluster details', {
          sections: [
            section('Details', [
              ['Engine', engineName(first?.Engine)],
              ['Engine version', first?.EngineVersion],
              ['Node type', rg.CacheNodeType],
              ['Cluster mode', rg.ClusterEnabled ? 'Enabled' : 'Disabled'],
              ['Shards', rg.NodeGroups?.length],
              ['Nodes', rg.MemberClusters?.length],
              ['Multi-AZ', rg.MultiAZ],
              ['Auto-failover', rg.AutomaticFailover],
              ['Data tiering', rg.DataTiering],
              ['Parameter group', first?.CacheParameterGroup?.CacheParameterGroupName],
              ['Global datastore', rg.GlobalReplicationGroupInfo?.GlobalReplicationGroupId],
              ['Created', rg.ReplicationGroupCreateTime],
            ]),
            { title: 'Endpoints', settings: [], copyable: endpoints },
            section('Backup and maintenance', [
              ['Automatic backups', rg.SnapshotRetentionLimit ? `${rg.SnapshotRetentionLimit} days retention` : 'Disabled'],
              ['Backup window', rg.SnapshotWindow],
              ['Maintenance window', first?.PreferredMaintenanceWindow],
              ['Auto minor version upgrade', rg.AutoMinorVersionUpgrade],
            ]),
            section('Logs', (rg.LogDeliveryConfigurations || []).map((l) => [l.LogType || 'log', `${l.LogFormat} → ${l.DestinationType} (${l.Status})`])),
          ].filter((s) => s.settings.length || s.copyable?.length),
        }),
        tab('Shards and nodes', {
          tables: (rg.NodeGroups || []).map((g) =>
            table(
              ['Node', 'Role', 'Availability Zone', 'Endpoint', 'Status'],
              (g.NodeGroupMembers || []).map((m) => [
                m.CacheClusterId,
                m.CurrentRole ?? (rg.ClusterEnabled ? 'shard member' : '-'),
                m.PreferredAvailabilityZone,
                endpointText(m.ReadEndpoint),
                memberById.get(m.CacheClusterId)?.CacheClusterStatus,
              ]),
              { title: `${g.NodeGroupId}${g.Slots ? ` · slots ${g.Slots}` : ''} · ${g.Status}`, statusColumn: 4 },
            ),
          ),
        }),
        tab('Network and security', { sections: [securitySection(first, [['Transit encryption mode', rg.TransitEncryptionMode], ['User groups', rg.UserGroupIds], ['KMS key', rg.KmsKeyId]])] }),
        tab('Backups', {
          tables: [
            table(
              ['Name', 'Source', 'Status', 'Created', 'Node type'],
              (snaps?.Snapshots || []).map((s) => [s.SnapshotName, s.SnapshotSource, s.SnapshotStatus, s.NodeSnapshots?.[0]?.SnapshotCreateTime, s.CacheNodeType]),
              { statusColumn: 2, emptyMessage: 'No backups' },
            ),
          ],
        }),
        await eventsTab(c, 'replication-group', name, errors),
      ],
      tags: tags ? tagList(tags.TagList) : undefined,
      actions: [],
      errors,
    };
  }

  if (kind === 'cc') {
    const cc = (await allCacheClusters(c, name, true))[0];
    if (!cc) throw httpError(`Cache cluster not found: ${name}`, 404);
    const { tags, snaps } = await settle(
      {
        tags: cc.ARN ? c.send(new ListTagsForResourceCommand({ ResourceName: cc.ARN })) : Promise.resolve(undefined),
        snaps: cc.Engine === 'memcached' ? Promise.resolve(undefined) : c.send(new DescribeSnapshotsCommand({ CacheClusterId: name })),
      },
      errors,
    );
    const tabs: PageTab[] = [
      tab('Cluster details', {
        sections: [
          section('Details', [
            ['Engine', engineName(cc.Engine)],
            ['Engine version', cc.EngineVersion],
            ['Node type', cc.CacheNodeType],
            ['Nodes', cc.NumCacheNodes],
            ['Availability Zone', cc.PreferredAvailabilityZone],
            ['Parameter group', cc.CacheParameterGroup?.CacheParameterGroupName],
            ['Maintenance window', cc.PreferredMaintenanceWindow],
            ['Auto minor version upgrade', cc.AutoMinorVersionUpgrade],
            ['Created', cc.CacheClusterCreateTime],
          ]),
          { title: 'Endpoints', settings: [], copyable: [{ label: 'Configuration endpoint', value: endpointText(cc.ConfigurationEndpoint) || '-' }].filter((e) => e.value !== '-') },
        ].filter((s) => s.settings.length || s.copyable?.length),
      }),
      tab('Nodes', {
        tables: [
          table(
            ['Node', 'Status', 'Availability Zone', 'Endpoint', 'Created'],
            (cc.CacheNodes || []).map((n) => [n.CacheNodeId, n.CacheNodeStatus, n.CustomerAvailabilityZone, endpointText(n.Endpoint), n.CacheNodeCreateTime]),
            { statusColumn: 1 },
          ),
        ],
      }),
      tab('Network and security', { sections: [securitySection(cc)] }),
    ];
    if (snaps) {
      tabs.push(tab('Backups', { tables: [table(['Name', 'Source', 'Status'], (snaps.Snapshots || []).map((s) => [s.SnapshotName, s.SnapshotSource, s.SnapshotStatus]), { statusColumn: 2, emptyMessage: 'No backups' })] }));
    }
    tabs.push(await eventsTab(c, 'cache-cluster', name, errors));
    return { id, title: name, subtitle: engineName(cc.Engine), status: cc.CacheClusterStatus, arn: cc.ARN, tabs, tags: tags ? tagList(tags.TagList) : undefined, actions: [], errors };
  }

  if (kind === 'sl') {
    const s = (await allServerless(c, name))[0];
    if (!s) throw httpError(`Serverless cache not found: ${name}`, 404);
    const { tags, snaps } = await settle(
      {
        tags: s.ARN ? c.send(new ListTagsForResourceCommand({ ResourceName: s.ARN })) : Promise.resolve(undefined),
        snaps: c.send(new DescribeServerlessCacheSnapshotsCommand({ ServerlessCacheName: name })),
      },
      errors,
    );
    const lim = s.CacheUsageLimits;
    return {
      id,
      title: name,
      subtitle: s.Description,
      status: s.Status,
      arn: s.ARN,
      tabs: [
        tab('Cache details', {
          sections: [
            section('Details', [
              ['Engine', engineName(s.Engine)],
              ['Engine version', s.FullEngineVersion ?? s.MajorEngineVersion],
              ['Maximum data storage', lim?.DataStorage?.Maximum !== undefined ? `${lim.DataStorage.Maximum} ${lim.DataStorage.Unit ?? 'GB'}` : 'No limit'],
              ['Maximum ECPU/s', lim?.ECPUPerSecond?.Maximum ?? 'No limit'],
              ['Daily backup time', s.DailySnapshotTime],
              ['Backup retention', s.SnapshotRetentionLimit !== undefined ? `${s.SnapshotRetentionLimit} days` : undefined],
              ['Created', s.CreateTime],
            ]),
            { title: 'Endpoints', settings: [], copyable: [
              { label: 'Endpoint', value: endpointText(s.Endpoint) || '-' },
              { label: 'Reader endpoint', value: endpointText(s.ReaderEndpoint) || '-' },
            ] },
          ],
        }),
        tab('Network and security', {
          sections: [section('Network and security', [['Subnets', s.SubnetIds], ['Security groups', s.SecurityGroupIds], ['User group', s.UserGroupId], ['KMS key', s.KmsKeyId ?? 'AWS owned key']])],
        }),
        tab('Backups', {
          tables: [
            table(
              ['Name', 'Type', 'Status', 'Created', 'Expires'],
              (snaps?.ServerlessCacheSnapshots || []).map((b) => [b.ServerlessCacheSnapshotName, b.SnapshotType, b.Status, b.CreateTime, b.ExpiryTime]),
              { statusColumn: 2, emptyMessage: 'No backups' },
            ),
          ],
        }),
      ],
      tags: tags ? tagList(tags.TagList) : undefined,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown ElastiCache id: ${id}`, 400);
}

export const elastiCacheAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new AddTagsToResourceCommand({ ResourceName: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new RemoveTagsFromResourceCommand({ ResourceName: arn, TagKeys: [key] }));
  },
};
