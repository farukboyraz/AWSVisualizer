import {
  GlueClient,
  GetDatabasesCommand,
  GetDatabaseCommand,
  GetTablesCommand,
  GetCrawlersCommand,
  GetCrawlerCommand,
  GetCrawlerMetricsCommand,
  GetJobsCommand,
  GetJobCommand,
  GetJobRunsCommand,
  GetConnectionsCommand,
  GetConnectionCommand,
  GetTagsCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-glue';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, accountId } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new GlueClient({ region: r, credentials: cachedCredentials(p) });

const TABLE_LIMIT = 500;
/** Job arguments / connection properties whose values are never shown. */
const SECRET_KEY = /pass(word)?|secret|token|credential|private.?key|api.?key|\bkey\b/i;
const mask = (k: string, v?: string) => (SECRET_KEY.test(k) ? '•••• (hidden)' : v);
const TAGGABLE: Record<string, string> = { crawl: 'crawler', job: 'job', conn: 'connection' };

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [dbs, crawlers, jobs, conns] = await Promise.all([
    pageAll((NextToken) => c.send(new GetDatabasesCommand({ NextToken })), (r) => r.DatabaseList, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new GetCrawlersCommand({ NextToken })), (r) => r.Crawlers, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new GetJobsCommand({ NextToken })), (r) => r.Jobs, (r) => r.NextToken).catch(() => []),
    // HidePassword: Glue would otherwise return connection passwords.
    pageAll((NextToken) => c.send(new GetConnectionsCommand({ NextToken, HidePassword: true })), (r) => r.ConnectionList, (r) => r.NextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...dbs.map((d) => ({ id: `db:${d.Name}`, name: d.Name || '', group: 'Databases', info: d.Description || d.LocationUri })).sort(byName),
    ...crawlers.map((x) => ({ id: `crawl:${x.Name}`, name: x.Name || '', group: 'Crawlers', status: x.LastCrawl?.Status ?? x.State, info: [x.DatabaseName && `→ ${x.DatabaseName}`, x.Schedule?.ScheduleExpression].filter(Boolean).join(' · ') })).sort(byName),
    ...jobs.map((j) => ({ id: `job:${j.Name}`, name: j.Name || '', group: 'ETL jobs', info: [j.Command?.Name, j.GlueVersion && `Glue ${j.GlueVersion}`, j.WorkerType && `${j.NumberOfWorkers}× ${j.WorkerType}`].filter(Boolean).join(' · ') })).sort(byName),
    ...conns.map((x) => ({ id: `conn:${x.Name}`, name: x.Name || '', group: 'Connections', status: x.Status, info: x.ConnectionType })).sort(byName),
  ];
}

async function glueArn(profile: string, region: string, kind: string, name: string) {
  return `arn:aws:glue:${region}:${await accountId(profile, region)}:${TAGGABLE[kind]}/${name}`;
}

async function databasePage(c: GlueClient, id: string, name: string): Promise<ResourcePage> {
  const d = (await c.send(new GetDatabaseCommand({ Name: name }))).Database;
  if (!d) throw httpError(`Database not found: ${name}`, 404);
  const errors: string[] = [];
  const { tables } = await settle({ tables: pageAll((NextToken) => c.send(new GetTablesCommand({ DatabaseName: name, NextToken })), (r) => r.TableList, (r) => r.NextToken, TABLE_LIMIT) }, errors);
  const rows = tables || [];
  return {
    id,
    title: name,
    subtitle: d.Description || 'Glue database',
    tabs: [
      tab('Tables', {
        tables: [
          table(
            ['Table', 'Type', 'Location', 'Format', 'Columns', 'Partition keys', 'Updated', 'Lake Formation'],
            rows.map((t) => [t.Name, t.TableType, t.StorageDescriptor?.Location, t.Parameters?.classification ?? t.StorageDescriptor?.InputFormat?.split('.').pop(), t.StorageDescriptor?.Columns?.length, (t.PartitionKeys || []).map((k) => k.Name), t.UpdateTime, t.IsRegisteredWithLakeFormation]),
            { title: rows.length >= TABLE_LIMIT ? `First ${TABLE_LIMIT} tables` : `${rows.length} tables`, emptyMessage: 'No tables' },
          ),
        ],
      }),
      tab('Details', {
        sections: [section('Database', [['Name', d.Name], ['Description', d.Description], ['Location', d.LocationUri], ['Catalog', d.CatalogId], ['Linked to', d.TargetDatabase ? `${d.TargetDatabase.CatalogId}:${d.TargetDatabase.DatabaseName}` : undefined], ['Federated', d.FederatedDatabase?.Identifier], ['Created', d.CreateTime]])],
        tables: [table(['Parameter', 'Value'], Object.entries(d.Parameters || {}), { title: 'Parameters', emptyMessage: 'No parameters' })],
      }),
    ],
    actions: [],
    errors,
  };
}

async function crawlerPage(c: GlueClient, profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const x = (await c.send(new GetCrawlerCommand({ Name: name }))).Crawler;
  if (!x) throw httpError(`Crawler not found: ${name}`, 404);
  const arn = await glueArn(profile, region, 'crawl', name);
  const errors: string[] = [];
  const parts = await settle({ metrics: c.send(new GetCrawlerMetricsCommand({ CrawlerNameList: [name] })), tags: c.send(new GetTagsCommand({ ResourceArn: arn })) }, errors);
  const m = parts.metrics?.CrawlerMetricsList?.[0];
  const t = x.Targets;
  const targets = [
    ...(t?.S3Targets || []).map((s) => ['S3', s.Path, (s.Exclusions || []).join(', ')]),
    ...(t?.JdbcTargets || []).map((s) => ['JDBC', `${s.ConnectionName}: ${s.Path}`, (s.Exclusions || []).join(', ')]),
    ...(t?.DynamoDBTargets || []).map((s) => ['DynamoDB', s.Path, '']),
    ...(t?.CatalogTargets || []).map((s) => ['Catalog', `${s.DatabaseName}: ${(s.Tables || []).join(', ')}`, '']),
    ...(t?.DeltaTargets || []).map((s) => ['Delta Lake', (s.DeltaTables || []).join(', '), '']),
    ...(t?.IcebergTargets || []).map((s) => ['Iceberg', (s.Paths || []).join(', '), '']),
  ];
  return {
    id,
    title: name,
    subtitle: x.Description || 'Glue crawler',
    status: x.LastCrawl?.Status ?? x.State,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Crawler', [
            ['State', x.State],
            ['Target database', x.DatabaseName],
            ['Table prefix', x.TablePrefix],
            ['Schedule', x.Schedule?.ScheduleExpression],
            ['Role', x.Role],
            ['Recrawl', x.RecrawlPolicy?.RecrawlBehavior],
            ['Schema changes', x.SchemaChangePolicy ? `${x.SchemaChangePolicy.UpdateBehavior} / ${x.SchemaChangePolicy.DeleteBehavior}` : undefined],
            ['Classifiers', x.Classifiers],
            ['Security configuration', x.CrawlerSecurityConfiguration],
            ['Created', x.CreationTime],
            ['Updated', x.LastUpdated],
          ]),
          section('Last crawl', [['Status', x.LastCrawl?.Status], ['Started', x.LastCrawl?.StartTime], ['Error', x.LastCrawl?.ErrorMessage], ['Log', x.LastCrawl?.LogGroup && `${x.LastCrawl.LogGroup}/${x.LastCrawl.LogStream ?? ''}`], ['Last runtime', m?.LastRuntimeSeconds !== undefined ? `${Math.round(m.LastRuntimeSeconds)} s` : undefined], ['Median runtime', m?.MedianRuntimeSeconds !== undefined ? `${Math.round(m.MedianRuntimeSeconds)} s` : undefined], ['Tables created / updated / deleted', m ? `${m.TablesCreated ?? 0} / ${m.TablesUpdated ?? 0} / ${m.TablesDeleted ?? 0}` : undefined]]),
        ],
        tables: [table(['Type', 'Target', 'Exclusions'], targets, { title: 'Data sources', emptyMessage: 'No targets' })],
      }),
    ],
    tags: tagMap(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function jobPage(c: GlueClient, profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const j = (await c.send(new GetJobCommand({ JobName: name }))).Job;
  if (!j) throw httpError(`Job not found: ${name}`, 404);
  const arn = await glueArn(profile, region, 'job', name);
  const errors: string[] = [];
  const parts = await settle({ runs: c.send(new GetJobRunsCommand({ JobName: name, MaxResults: 25 })), tags: c.send(new GetTagsCommand({ ResourceArn: arn })) }, errors);
  const runs = parts.runs?.JobRuns || [];
  return {
    id,
    title: name,
    subtitle: j.Description || `${j.Command?.Name ?? ''} job`,
    status: runs[0]?.JobRunState,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Job', [
            ['Type', j.Command?.Name],
            ['Script', j.Command?.ScriptLocation],
            ['Language', j.Command?.PythonVersion ? `Python ${j.Command.PythonVersion}` : undefined],
            ['Glue version', j.GlueVersion],
            ['Workers', j.WorkerType ? `${j.NumberOfWorkers} × ${j.WorkerType}` : j.MaxCapacity !== undefined ? `${j.MaxCapacity} DPU` : undefined],
            ['Execution class', j.ExecutionClass],
            ['Max concurrent runs', j.ExecutionProperty?.MaxConcurrentRuns],
            ['Retries', j.MaxRetries],
            ['Timeout (min)', j.Timeout],
            ['Connections', j.Connections?.Connections],
            ['Role', j.Role],
            ['Security configuration', j.SecurityConfiguration],
            ['Created', j.CreatedOn],
            ['Modified', j.LastModifiedOn],
          ]),
        ],
        tables: [table(['Argument', 'Value'], Object.entries(j.DefaultArguments || {}).map(([k, v]) => [k, mask(k, v)]), { title: 'Default arguments', emptyMessage: 'No default arguments' })],
      }),
      tab('Runs', {
        tables: [
          table(['Run', 'State', 'Started', 'Completed', 'Time (s)', 'DPU-seconds', 'Trigger', 'Error'], runs.map((r) => [r.Id?.slice(0, 16), r.JobRunState, r.StartedOn, r.CompletedOn, r.ExecutionTime, r.DPUSeconds, r.TriggerName, r.ErrorMessage]), {
            statusColumn: 1,
            title: 'Last 25 runs',
            emptyMessage: 'Never run',
          }),
        ],
      }),
    ],
    tags: tagMap(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function connectionPage(c: GlueClient, profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const x = (await c.send(new GetConnectionCommand({ Name: name, HidePassword: true }))).Connection;
  if (!x) throw httpError(`Connection not found: ${name}`, 404);
  const arn = await glueArn(profile, region, 'conn', name);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new GetTagsCommand({ ResourceArn: arn })) }, errors);
  const net = x.PhysicalConnectionRequirements;
  return {
    id,
    title: name,
    subtitle: `${x.ConnectionType ?? ''} connection`,
    status: x.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Connection', [
            ['Type', x.ConnectionType],
            ['Status', x.Status],
            ['Status reason', x.StatusReason],
            ['Description', x.Description],
            ['Authentication', x.AuthenticationConfiguration?.AuthenticationType],
            ['Credentials secret', x.AuthenticationConfiguration?.SecretArn],
            ['Subnet', net?.SubnetId],
            ['Availability Zone', net?.AvailabilityZone],
            ['Security groups', net?.SecurityGroupIdList],
            ['Last validated', x.LastConnectionValidationTime],
            ['Updated', x.LastUpdatedTime],
            ['Updated by', x.LastUpdatedBy],
          ]),
        ],
        tables: [table(['Property', 'Value'], Object.entries(x.ConnectionProperties || {}).map(([k, v]) => [k, mask(k, v)]), { title: 'Properties', emptyMessage: 'No properties' })],
      }),
    ],
    tags: tagMap(tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  if (kind === 'db') return databasePage(c, id, name);
  if (kind === 'crawl') return crawlerPage(c, profile, region, id, name);
  if (kind === 'job') return jobPage(c, profile, region, id, name);
  if (kind === 'conn') return connectionPage(c, profile, region, id, name);
  throw httpError(`Unknown Glue page: ${id}`, 400);
}

async function tagTarget(profile: string, region: string, id: string) {
  const [kind, name] = splitId(id);
  if (!TAGGABLE[kind]) throw httpError('Only crawlers, jobs and connections can be tagged here', 400);
  return glueArn(profile, region, kind, name);
}

export const glueAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: await tagTarget(profile, region, id), TagsToAdd: { [key]: value } }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: await tagTarget(profile, region, id), TagsToRemove: [key] }));
  },
  countable: (row) => row.id.startsWith('db:') || row.id.startsWith('job:'),
};
