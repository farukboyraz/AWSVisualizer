import {
  DatabaseMigrationServiceClient,
  DescribeReplicationTasksCommand,
  DescribeReplicationInstancesCommand,
  DescribeEndpointsCommand,
  DescribeTableStatisticsCommand,
  DescribeConnectionsCommand,
  DescribeEventsCommand,
  ListTagsForResourceCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  StartReplicationTaskCommand,
  StopReplicationTaskCommand,
  type ReplicationTask,
  type ReplicationInstance,
  type Endpoint,
  type Filter,
} from '@aws-sdk/client-database-migration-service';
import { cachedCredentials } from './credential-cache.js';
import type { PageAction, ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError, EVENT_WINDOW_MINUTES } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new DatabaseMigrationServiceClient({ region: r, credentials: cachedCredentials(p) });

async function tasks(c: DatabaseMigrationServiceClient, Filters?: Filter[], withSettings = false): Promise<ReplicationTask[]> {
  const out: ReplicationTask[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeReplicationTasksCommand({ Filters, Marker, WithoutSettings: !withSettings }));
    out.push(...(res.ReplicationTasks || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

async function instances(c: DatabaseMigrationServiceClient, Filters?: Filter[]): Promise<ReplicationInstance[]> {
  const out: ReplicationInstance[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeReplicationInstancesCommand({ Filters, Marker }));
    out.push(...(res.ReplicationInstances || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

async function endpoints(c: DatabaseMigrationServiceClient, Filters?: Filter[]): Promise<Endpoint[]> {
  const out: Endpoint[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeEndpointsCommand({ Filters, Marker }));
    out.push(...(res.Endpoints || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

/** DMS treats "not found" in a filter as an error; empty results are fine. */
const isNotFound = (err: unknown) => (err as { name?: string })?.name === 'ResourceNotFoundFault';

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [ts, is, es] = await Promise.all([
    tasks(c).catch((e) => (isNotFound(e) ? [] : Promise.reject(e))),
    instances(c).catch((e) => (isNotFound(e) ? [] : Promise.reject(e))),
    endpoints(c).catch((e) => (isNotFound(e) ? [] : Promise.reject(e))),
  ]);
  const epName = new Map(es.map((e) => [e.EndpointArn, e.EndpointIdentifier]));
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...ts.map((t) => ({
      id: `task:${t.ReplicationTaskArn}`,
      name: t.ReplicationTaskIdentifier || '',
      group: '1 Database migration tasks',
      status: t.Status,
      info: [t.MigrationType, `${epName.get(t.SourceEndpointArn) ?? '?'} → ${epName.get(t.TargetEndpointArn) ?? '?'}`, t.ReplicationTaskStats?.FullLoadProgressPercent !== undefined ? `${t.ReplicationTaskStats.FullLoadProgressPercent}%` : undefined].filter(Boolean).join(' · '),
    })).sort(byName),
    ...is.map((i) => ({
      id: `ri:${i.ReplicationInstanceArn}`,
      name: i.ReplicationInstanceIdentifier || '',
      group: '2 Replication instances',
      status: i.ReplicationInstanceStatus,
      info: [i.ReplicationInstanceClass, i.EngineVersion, i.MultiAZ ? 'Multi-AZ' : i.AvailabilityZone].filter(Boolean).join(' · '),
    })).sort(byName),
    ...es.map((e) => ({
      id: `ep:${e.EndpointArn}`,
      name: e.EndpointIdentifier || '',
      group: '3 Endpoints',
      status: e.Status,
      info: [e.EndpointType === 'source' ? 'Source' : 'Target', e.EngineDisplayName ?? e.EngineName, e.ServerName].filter(Boolean).join(' · '),
    })).sort(byName),
  ].map((s) => ({ ...s, group: s.group.slice(2) }));
}

function taskActions(t: ReplicationTask): PageAction[] {
  const name = t.ReplicationTaskIdentifier;
  switch (t.Status) {
    case 'running':
      return [{ id: 'stop', title: 'Stop', systemImage: 'stop.fill', confirmTitle: `Stop ${name}?`, confirmMessage: 'Replication stops; it can be resumed later from the last checkpoint.', destructive: true }];
    case 'stopped':
    case 'failed':
      return [{ id: 'resume', title: 'Resume', systemImage: 'play.fill', confirmTitle: `Resume ${name}?`, confirmMessage: 'Replication continues from where it stopped (resume-processing). Tables are not reloaded.', destructive: false }];
    case 'ready':
      return [{ id: 'start', title: 'Start', systemImage: 'play.fill', confirmTitle: `Start ${name}?`, confirmMessage: 'Starts the migration for the first time; the full load writes to the target endpoint.', destructive: false }];
    default:
      return [];
  }
}

/** JSON settings come back as strings - reformat for reading. */
const pretty = (raw?: string) => {
  if (!raw) return undefined;
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
};

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  const errors: string[] = [];

  if (kind === 'task') {
    const t = (await tasks(c, [{ Name: 'replication-task-arn', Values: [arn] }], true))[0];
    if (!t) throw httpError('Task not found', 404);
    const { eps, stats, events, tags } = await settle(
      {
        eps: endpoints(c, [{ Name: 'endpoint-arn', Values: [t.SourceEndpointArn || '', t.TargetEndpointArn || ''] }]),
        stats: c.send(new DescribeTableStatisticsCommand({ ReplicationTaskArn: arn, MaxRecords: 500 })),
        // The SDK enum only lists replication-instance; the API also accepts replication-task.
        events: c.send(new DescribeEventsCommand({ SourceType: 'replication-task' as 'replication-instance', SourceIdentifier: t.ReplicationTaskIdentifier, Duration: EVENT_WINDOW_MINUTES })),
        tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
      },
      errors,
    );
    const ep = (a?: string) => eps?.find((e) => e.EndpointArn === a);
    const st = t.ReplicationTaskStats;
    return {
      id,
      title: t.ReplicationTaskIdentifier || '',
      subtitle: t.MigrationType,
      status: t.Status,
      arn,
      tabs: [
        tab('Overview', {
          sections: [
            section('Task', [
              ['Status', t.Status],
              ['Migration type', t.MigrationType],
              ['Source endpoint', ep(t.SourceEndpointArn) ? `${ep(t.SourceEndpointArn)?.EndpointIdentifier} (${ep(t.SourceEndpointArn)?.EngineName})` : t.SourceEndpointArn],
              ['Target endpoint', ep(t.TargetEndpointArn) ? `${ep(t.TargetEndpointArn)?.EndpointIdentifier} (${ep(t.TargetEndpointArn)?.EngineName})` : t.TargetEndpointArn],
              ['Replication instance', t.ReplicationInstanceArn?.split(':').pop()],
              ['Created', t.ReplicationTaskCreationDate],
              ['Last started', t.ReplicationTaskStartDate],
              ['CDC start position', t.CdcStartPosition],
              ['CDC stop position', t.CdcStopPosition],
              ['Stop reason', t.StopReason],
              ['Last failure', t.LastFailureMessage],
            ]),
            section('Progress', [
              ['Full load progress', st?.FullLoadProgressPercent !== undefined ? `${st.FullLoadProgressPercent}%` : undefined],
              ['Tables loaded', st?.TablesLoaded],
              ['Tables loading', st?.TablesLoading],
              ['Tables queued', st?.TablesQueued],
              ['Tables errored', st?.TablesErrored],
              ['Elapsed', st?.ElapsedTimeMillis !== undefined ? `${Math.round(st.ElapsedTimeMillis / 60000)} min` : undefined],
              ['Full load finished', st?.FullLoadFinishDate],
            ]),
          ],
        }),
        tab('Table statistics', {
          tables: [
            table(
              ['Schema', 'Table', 'State', 'Full load rows', 'Inserts', 'Updates', 'Deletes', 'DDLs', 'Errors', 'Validation'],
              (stats?.TableStatistics || []).map((s) => [s.SchemaName, s.TableName, s.TableState, s.FullLoadRows, s.Inserts, s.Updates, s.Deletes, s.Ddls, s.FullLoadErrorRows, s.ValidationState]),
              { statusColumn: 2, emptyMessage: 'No table statistics yet - they appear once the task starts.' },
            ),
          ],
        }),
        tab('Table mappings', { json: pretty(t.TableMappings), emptyMessage: 'No table mappings' }),
        tab('Task settings', { json: pretty(t.ReplicationTaskSettings), emptyMessage: 'No task settings' }),
        tab('Events', { tables: [table(['Date', 'Categories', 'Message'], (events?.Events || []).map((e) => [e.Date, e.EventCategories, e.Message]), { emptyMessage: 'No events in the last 7 days' })] }),
      ],
      tags: tags ? tagList(tags.TagList) : undefined,
      actions: taskActions(t),
      errors,
    };
  }

  if (kind === 'ri') {
    const i = (await instances(c, [{ Name: 'replication-instance-arn', Values: [arn] }]))[0];
    if (!i) throw httpError('Replication instance not found', 404);
    const { ts, tags } = await settle(
      {
        ts: tasks(c, [{ Name: 'replication-instance-arn', Values: [arn] }]).catch((e) => (isNotFound(e) ? [] : Promise.reject(e))),
        tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
      },
      errors,
    );
    return {
      id,
      title: i.ReplicationInstanceIdentifier || '',
      subtitle: `${i.ReplicationInstanceClass} · ${i.EngineVersion}`,
      status: i.ReplicationInstanceStatus,
      arn,
      tabs: [
        tab('Details', {
          sections: [
            section('Configuration', [
              ['Class', i.ReplicationInstanceClass],
              ['Engine version', i.EngineVersion],
              ['Allocated storage', i.AllocatedStorage !== undefined ? `${i.AllocatedStorage} GiB` : undefined],
              ['Multi-AZ', i.MultiAZ],
              ['Availability Zone', i.AvailabilityZone],
              ['Secondary AZ', i.SecondaryAvailabilityZone],
              ['Maintenance window', i.PreferredMaintenanceWindow],
              ['Auto minor version upgrade', i.AutoMinorVersionUpgrade],
              ['Created', i.InstanceCreateTime],
              ['Free until', i.FreeUntil],
            ]),
            section('Network and security', [
              ['VPC', i.ReplicationSubnetGroup?.VpcId],
              ['Subnet group', i.ReplicationSubnetGroup?.ReplicationSubnetGroupIdentifier],
              ['Security groups', (i.VpcSecurityGroups || []).map((g) => g.VpcSecurityGroupId)],
              ['Publicly accessible', i.PubliclyAccessible],
              ['Private IPs', i.ReplicationInstancePrivateIpAddresses],
              ['Public IPs', i.ReplicationInstancePublicIpAddresses],
              ['Network type', i.NetworkType],
              ['KMS key', i.KmsKeyId],
            ]),
          ],
        }),
        tab('Tasks', {
          tables: [table(['Task', 'Type', 'Status'], (ts || []).map((t) => [t.ReplicationTaskIdentifier, t.MigrationType, t.Status]), { statusColumn: 2, emptyMessage: 'No tasks use this instance' })],
        }),
      ],
      tags: tags ? tagList(tags.TagList) : undefined,
      actions: [],
      errors,
    };
  }

  if (kind === 'ep') {
    const e = (await endpoints(c, [{ Name: 'endpoint-arn', Values: [arn] }]))[0];
    if (!e) throw httpError('Endpoint not found', 404);
    const { conns, tags } = await settle(
      {
        conns: c.send(new DescribeConnectionsCommand({ Filters: [{ Name: 'endpoint-arn', Values: [arn] }] })),
        tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
      },
      errors,
      isNotFound,
    );
    return {
      id,
      title: e.EndpointIdentifier || '',
      subtitle: `${e.EndpointType === 'source' ? 'Source' : 'Target'} · ${e.EngineDisplayName ?? e.EngineName}`,
      status: e.Status,
      arn,
      tabs: [
        tab('Details', {
          sections: [
            // Engine-specific settings objects may contain passwords - only these plain fields are returned.
            section('Endpoint', [
              ['Type', e.EndpointType],
              ['Engine', e.EngineDisplayName ?? e.EngineName],
              ['Server', e.ServerName],
              ['Port', e.Port],
              ['Database', e.DatabaseName],
              ['User', e.Username],
              ['SSL mode', e.SslMode],
              ['Certificate', e.CertificateArn?.split(':').pop()],
              ['Service access role', e.ServiceAccessRoleArn?.split('/').pop()],
              ['Extra connection attributes', e.ExtraConnectionAttributes],
              ['KMS key', e.KmsKeyId],
            ]),
          ],
        }),
        tab('Connections', {
          tables: [
            table(
              ['Replication instance', 'Status', 'Last failure'],
              (conns?.Connections || []).map((cn) => [cn.ReplicationInstanceIdentifier, cn.Status, cn.LastFailureMessage]),
              { statusColumn: 1, emptyMessage: 'This endpoint has not been tested from a replication instance' },
            ),
          ],
        }),
      ],
      tags: tags ? tagList(tags.TagList) : undefined,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown DMS id: ${id}`, 400);
}

export const dmsAdapter: PageServiceAdapter = {
  list,
  detail,
  async action(profile, region, id, action) {
    const [kind, arn] = splitId(id);
    if (kind !== 'task') throw httpError('Actions are only available for migration tasks', 400);
    const c = client(profile, region);
    if (action === 'stop') await c.send(new StopReplicationTaskCommand({ ReplicationTaskArn: arn }));
    else if (action === 'resume') await c.send(new StartReplicationTaskCommand({ ReplicationTaskArn: arn, StartReplicationTaskType: 'resume-processing' }));
    else if (action === 'start') await c.send(new StartReplicationTaskCommand({ ReplicationTaskArn: arn, StartReplicationTaskType: 'start-replication' }));
    else throw httpError('action must be start, resume or stop', 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new AddTagsToResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new RemoveTagsFromResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
};
