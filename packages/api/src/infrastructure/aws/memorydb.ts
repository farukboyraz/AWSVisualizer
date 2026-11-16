import {
  MemoryDBClient,
  DescribeClustersCommand,
  DescribeSnapshotsCommand,
  DescribeACLsCommand,
  DescribeEventsCommand,
  ListTagsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Cluster,
} from '@aws-sdk/client-memorydb';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, endpointText, httpError, EVENT_WINDOW_MINUTES } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

function client(profile: string, region: string) {
  return new MemoryDBClient({ region, credentials: cachedCredentials(profile) });
}

async function clusters(c: MemoryDBClient, name?: string, details = false): Promise<Cluster[]> {
  const out: Cluster[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new DescribeClustersCommand({ ClusterName: name, NextToken, ShowShardDetails: details }));
    out.push(...(res.Clusters || []));
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const items = await clusters(client(profile, region));
  return items
    .map((cl) => ({
      id: cl.Name || '',
      name: cl.Name || '',
      status: cl.Status,
      info: [cl.EngineVersion && `Redis OSS ${cl.EngineVersion}`, cl.NodeType, `${cl.NumberOfShards ?? 0} shards`].filter(Boolean).join(' · '),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, name: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const cl = (await clusters(c, name, true))[0];
  if (!cl) throw httpError(`Cluster not found: ${name}`, 404);
  const errors: string[] = [];
  const { snaps, acl, events, tags } = await settle(
    {
      snaps: c.send(new DescribeSnapshotsCommand({ ClusterName: name })),
      acl: cl.ACLName ? c.send(new DescribeACLsCommand({ ACLName: cl.ACLName })) : Promise.resolve(undefined),
      events: c.send(new DescribeEventsCommand({ SourceName: name, SourceType: 'cluster', Duration: EVENT_WINDOW_MINUTES })),
      tags: cl.ARN ? c.send(new ListTagsCommand({ ResourceArn: cl.ARN })) : Promise.resolve(undefined),
    },
    errors,
  );
  const a = acl?.ACLs?.[0];
  return {
    id: name,
    title: name,
    subtitle: cl.Description,
    status: cl.Status,
    arn: cl.ARN,
    tabs: [
      tab('Cluster details', {
        sections: [
          section('Details', [
            ['Engine version', cl.EnginePatchVersion ?? cl.EngineVersion],
            ['Node type', cl.NodeType],
            ['Shards', cl.NumberOfShards],
            ['Multi-AZ', cl.AvailabilityMode],
            ['Data tiering', cl.DataTiering],
            ['Parameter group', cl.ParameterGroupName && `${cl.ParameterGroupName} (${cl.ParameterGroupStatus})`],
            ['Pending updates', [cl.PendingUpdates?.Resharding && 'resharding', cl.PendingUpdates?.ServiceUpdates?.length && `${cl.PendingUpdates.ServiceUpdates.length} service updates`].filter(Boolean)],
          ]),
          { title: 'Cluster endpoint', settings: [], copyable: [{ label: 'Endpoint', value: endpointText(cl.ClusterEndpoint) || '-' }] },
          section('Backup and maintenance', [
            ['Automatic snapshots', cl.SnapshotRetentionLimit ? `${cl.SnapshotRetentionLimit} days retention` : 'Disabled'],
            ['Snapshot window', cl.SnapshotWindow],
            ['Maintenance window', cl.MaintenanceWindow],
            ['Auto minor version upgrade', cl.AutoMinorVersionUpgrade],
            ['SNS topic', cl.SnsTopicArn && `${cl.SnsTopicArn} (${cl.SnsTopicStatus})`],
          ]),
        ],
      }),
      tab('Shards and nodes', {
        tables: (cl.Shards || []).map((s) =>
          table(['Node', 'Availability Zone', 'Endpoint', 'Created', 'Status'], (s.Nodes || []).map((n) => [n.Name, n.AvailabilityZone, endpointText(n.Endpoint), n.CreateTime, n.Status]), {
            title: `${s.Name}${s.Slots ? ` · slots ${s.Slots}` : ''} · ${s.Status}`,
            statusColumn: 4,
          }),
        ),
      }),
      tab('Network and security', {
        sections: [
          section('Network and security', [
            ['Subnet group', cl.SubnetGroupName],
            ['Security groups', (cl.SecurityGroups || []).map((g) => `${g.SecurityGroupId} (${g.Status})`)],
            ['Encryption in transit (TLS)', cl.TLSEnabled],
            ['KMS key', cl.KmsKeyId ?? 'AWS owned key'],
          ]),
          section('Access control list', [
            ['ACL', cl.ACLName],
            ['Status', a?.Status],
            ['Users', a?.UserNames],
            ['Minimum engine version', a?.MinimumEngineVersion],
          ]),
        ],
      }),
      tab('Snapshots', {
        tables: [table(['Name', 'Source', 'Status'], (snaps?.Snapshots || []).map((s) => [s.Name, s.Source, s.Status]), { statusColumn: 2, emptyMessage: 'No snapshots' })],
      }),
      tab('Events', {
        tables: [table(['Date', 'Message'], (events?.Events || []).map((e) => [e.Date, e.Message]), { emptyMessage: 'No events in the last 7 days' })],
      }),
    ],
    tags: tags ? tagList(tags.TagList) : undefined,
    actions: [],
    errors,
  };
}

export const memoryDbAdapter: PageServiceAdapter = singleKind('cluster', {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
});
