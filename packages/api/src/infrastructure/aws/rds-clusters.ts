import {
  RDSClient,
  DescribeDBClustersCommand,
  DescribeDBInstancesCommand,
  DescribeDBClusterSnapshotsCommand,
  DescribeEventsCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  StartDBClusterCommand,
  StopDBClusterCommand,
  CreateDBClusterSnapshotCommand,
  type DBCluster,
} from '@aws-sdk/client-rds';
import { cachedCredentials } from './credential-cache.js';
import type { PageAction, ResourcePage, PageSummary, StorageSetting } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError, metricChart, snapshotNameField, nameStamp, EVENT_WINDOW_MINUTES } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

/**
 * Neptune and DocumentDB are managed through the RDS API with their own
 * engine names; one adapter factory serves both.
 */
interface ClusterEngine {
  engine: 'neptune' | 'docdb';
  label: string;
  connection: (cl: DBCluster) => StorageSetting[];
  /** CloudWatch namespace for the Monitoring tab and its graphs (`[metric, stat, label?]`, unit). */
  namespace: string;
  charts: { title: string; unit?: string; metrics: [string, string, string?][] }[];
}

const client = (p: string, r: string) => new RDSClient({ region: r, credentials: cachedCredentials(p) });

async function clusters(c: RDSClient, engine: string, id?: string): Promise<DBCluster[]> {
  const out: DBCluster[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(
      new DescribeDBClustersCommand(id ? { DBClusterIdentifier: id } : { Filters: [{ Name: 'engine', Values: [engine] }], Marker }),
    );
    out.push(...(res.DBClusters || []).filter((cl) => cl.Engine === engine));
    Marker = id ? undefined : res.Marker;
  } while (Marker);
  return out;
}

function actions(cl: DBCluster, label: string): PageAction[] {
  if (cl.Status === 'available') {
    return [
      {
        id: 'snapshot',
        title: 'Take snapshot',
        systemImage: 'camera',
        confirmTitle: `Take a snapshot of ${cl.DBClusterIdentifier}?`,
        confirmMessage: 'A manual cluster snapshot is created. It stays until you delete it and its storage is billed.',
        destructive: false,
        form: [snapshotNameField(`${cl.DBClusterIdentifier}-manual-${nameStamp()}`)],
      },
      { id: 'stop', title: 'Stop', systemImage: 'stop.fill', confirmTitle: `Stop ${cl.DBClusterIdentifier}?`, confirmMessage: `All instances of the ${label} cluster stop; storage is still billed. AWS starts it again automatically after 7 days.`, destructive: true },
    ];
  }
  if (cl.Status === 'stopped') {
    return [{ id: 'start', title: 'Start', systemImage: 'play.fill', confirmTitle: `Start ${cl.DBClusterIdentifier}?`, confirmMessage: 'The cluster and its instances start and billing resumes.', destructive: false }];
  }
  return [];
}

function makeAdapter(spec: ClusterEngine): PageServiceAdapter {
  return {
    async list(profile, region): Promise<PageSummary[]> {
      const items = await clusters(client(profile, region), spec.engine);
      return items
        .map((cl) => ({
          id: cl.DBClusterIdentifier || '',
          name: cl.DBClusterIdentifier || '',
          status: cl.Status,
          info: [`${spec.label} ${cl.EngineVersion ?? ''}`.trim(), `${cl.DBClusterMembers?.length ?? 0} instances`, cl.ServerlessV2ScalingConfiguration ? 'serverless' : undefined].filter(Boolean).join(' · '),
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
    },

    async detail(profile, region, id): Promise<ResourcePage> {
      const c = client(profile, region);
      const cl = (await clusters(c, spec.engine, id))[0];
      if (!cl) throw httpError(`${spec.label} cluster not found: ${id}`, 404);
      const errors: string[] = [];
      const { instances, snaps, events } = await settle(
        {
          instances: c.send(new DescribeDBInstancesCommand({ Filters: [{ Name: 'db-cluster-id', Values: [id] }] })),
          snaps: c.send(new DescribeDBClusterSnapshotsCommand({ DBClusterIdentifier: id })),
          events: c.send(new DescribeEventsCommand({ SourceType: 'db-cluster', SourceIdentifier: id, Duration: EVENT_WINDOW_MINUTES })),
        },
        errors,
      );
      const writer = new Set((cl.DBClusterMembers || []).filter((m) => m.IsClusterWriter).map((m) => m.DBInstanceIdentifier));
      const sv2 = cl.ServerlessV2ScalingConfiguration;
      return {
        id,
        title: id,
        subtitle: `${spec.label} ${cl.EngineVersion ?? ''}`.trim(),
        status: cl.Status,
        arn: cl.DBClusterArn,
        tabs: [
          tab('Configuration', {
            sections: [
              section('Cluster', [
                ['Engine version', cl.EngineVersion],
                ['Status', cl.Status],
                ['Instances', cl.DBClusterMembers?.length],
                ['Serverless v2 capacity', sv2 && `${sv2.MinCapacity}-${sv2.MaxCapacity} NCU`],
                ['Multi-AZ', cl.MultiAZ],
                ['Port', cl.Port],
                ['Parameter group', cl.DBClusterParameterGroup],
                ['IAM authentication', cl.IAMDatabaseAuthenticationEnabled],
                ['Master user', cl.MasterUsername],
                ['Deletion protection', cl.DeletionProtection],
                ['Created', cl.ClusterCreateTime],
              ]),
              {
                title: 'Endpoints',
                settings: [],
                copyable: [
                  { label: 'Cluster (writer) endpoint', value: cl.Endpoint ?? '-' },
                  { label: 'Reader endpoint', value: cl.ReaderEndpoint ?? '-' },
                  ...(cl.CustomEndpoints || []).map((e) => ({ label: 'Custom endpoint', value: e })),
                  ...spec.connection(cl),
                ].filter((e) => e.value !== '-'),
              },
            ],
          }),
          tab('Instances', {
            tables: [
              table(
                ['Instance', 'Role', 'Class', 'Availability Zone', 'Status'],
                (instances?.DBInstances || []).map((i) => [i.DBInstanceIdentifier, writer.has(i.DBInstanceIdentifier) ? 'Writer' : 'Reader', i.DBInstanceClass, i.AvailabilityZone, i.DBInstanceStatus]),
                { statusColumn: 4, emptyMessage: 'No instances in this cluster' },
              ),
            ],
          }),
          tab('Monitoring', {
            charts: spec.charts.map((ch) => metricChart(ch.title, spec.namespace, { DBClusterIdentifier: id }, ch.metrics, ch.unit)),
          }),
          tab('Connectivity & security', {
            sections: [
              section('Network and security', [
                ['Subnet group', cl.DBSubnetGroup],
                ['Availability Zones', cl.AvailabilityZones],
                ['Security groups', (cl.VpcSecurityGroups || []).map((g) => `${g.VpcSecurityGroupId} (${g.Status})`)],
                ['Network type', cl.NetworkType],
                ['Storage encrypted', cl.StorageEncrypted],
                ['KMS key', cl.KmsKeyId],
                ['IAM roles', (cl.AssociatedRoles || []).map((r) => `${r.RoleArn?.split('/').pop()} (${r.Status})`)],
                ['CA certificate', cl.CertificateDetails?.CAIdentifier],
              ]),
            ],
          }),
          tab('Maintenance & backups', {
            sections: [
              section('Maintenance and backups', [
                ['Backup retention', cl.BackupRetentionPeriod !== undefined ? `${cl.BackupRetentionPeriod} days` : undefined],
                ['Backup window', cl.PreferredBackupWindow],
                ['Maintenance window', cl.PreferredMaintenanceWindow],
                ['Earliest restorable time', cl.EarliestRestorableTime],
                ['Latest restorable time', cl.LatestRestorableTime],
                ['Log exports', cl.EnabledCloudwatchLogsExports],
                ['Copy tags to snapshots', cl.CopyTagsToSnapshot],
              ]),
            ],
            tables: [
              table(
                ['Snapshot', 'Type', 'Status', 'Created', 'Encrypted'],
                (snaps?.DBClusterSnapshots || [])
                  .sort((a, b) => (b.SnapshotCreateTime?.getTime() || 0) - (a.SnapshotCreateTime?.getTime() || 0))
                  .map((s) => [s.DBClusterSnapshotIdentifier, s.SnapshotType, s.Status, s.SnapshotCreateTime, s.StorageEncrypted]),
                { title: 'Snapshots', statusColumn: 2, emptyMessage: 'No snapshots' },
              ),
            ],
          }),
          tab('Events', {
            tables: [table(['Date', 'Message'], (events?.Events || []).map((e) => [e.Date, e.Message]), { emptyMessage: 'No events in the last 7 days' })],
          }),
        ],
        tags: tagList(cl.TagList),
        actions: actions(cl, spec.label),
        errors,
      };
    },

    async action(profile, region, id, action, params) {
      const c = client(profile, region);
      if (action === 'start') await c.send(new StartDBClusterCommand({ DBClusterIdentifier: id }));
      else if (action === 'stop') await c.send(new StopDBClusterCommand({ DBClusterIdentifier: id }));
      else if (action === 'snapshot') await c.send(new CreateDBClusterSnapshotCommand({ DBClusterIdentifier: id, DBClusterSnapshotIdentifier: params.name }));
      else throw httpError('action must be start, stop or snapshot', 400);
    },
    async addTag(profile, region, _id, arn, key, value) {
      await client(profile, region).send(new AddTagsToResourceCommand({ ResourceName: arn, Tags: [{ Key: key, Value: value }] }));
    },
    async removeTag(profile, region, _id, arn, key) {
      await client(profile, region).send(new RemoveTagsFromResourceCommand({ ResourceName: arn, TagKeys: [key] }));
    },
  };
}

export const neptuneAdapter = singleKind('cluster', makeAdapter({
  engine: 'neptune',
  label: 'Neptune',
  namespace: 'AWS/Neptune',
  charts: [
    { title: 'CPU utilization', unit: '%', metrics: [['CPUUtilization', 'Average']] },
    { title: 'Freeable memory', unit: 'Bytes', metrics: [['FreeableMemory', 'Minimum']] },
    { title: 'Requests per second', metrics: [['GremlinRequestsPerSec', 'Average', 'Gremlin'], ['SparqlRequestsPerSec', 'Average', 'SPARQL'], ['OpenCypherRequestsPerSec', 'Average', 'openCypher']] },
    { title: 'Pending requests', metrics: [['MainRequestQueuePendingRequests', 'Maximum']] },
  ],
  connection: (cl) =>
    cl.Endpoint
      ? [
          { label: 'Gremlin (WebSocket)', value: `wss://${cl.Endpoint}:${cl.Port ?? 8182}/gremlin` },
          { label: 'SPARQL', value: `https://${cl.Endpoint}:${cl.Port ?? 8182}/sparql` },
          { label: 'openCypher', value: `https://${cl.Endpoint}:${cl.Port ?? 8182}/openCypher` },
          { label: 'Status check', value: `curl https://${cl.Endpoint}:${cl.Port ?? 8182}/status` },
        ]
      : [],
}));

export const documentDbAdapter = singleKind('cluster', makeAdapter({
  engine: 'docdb',
  label: 'DocumentDB',
  namespace: 'AWS/DocDB',
  charts: [
    { title: 'CPU utilization', unit: '%', metrics: [['CPUUtilization', 'Average']] },
    { title: 'Connections', metrics: [['DatabaseConnections', 'Maximum']] },
    { title: 'Freeable memory', unit: 'Bytes', metrics: [['FreeableMemory', 'Minimum']] },
    { title: 'Operations', metrics: [['OpcountersQuery', 'Sum', 'Query'], ['OpcountersInsert', 'Sum', 'Insert'], ['OpcountersUpdate', 'Sum', 'Update'], ['OpcountersDelete', 'Sum', 'Delete']] },
  ],
  connection: (cl) =>
    cl.Endpoint
      ? [
          { label: 'mongosh', value: `mongosh --tls --host ${cl.Endpoint}:${cl.Port ?? 27017} --tlsCAFile global-bundle.pem --username ${cl.MasterUsername ?? '<user>'} --password` },
          { label: 'Connection string', value: `mongodb://${cl.MasterUsername ?? '<user>'}:<password>@${cl.Endpoint}:${cl.Port ?? 27017}/?tls=true&tlsCAFile=global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false` },
        ]
      : [],
}));
