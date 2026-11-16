import {
  AthenaClient,
  ListWorkGroupsCommand,
  GetWorkGroupCommand,
  ListQueryExecutionsCommand,
  BatchGetQueryExecutionCommand,
  ListNamedQueriesCommand,
  BatchGetNamedQueryCommand,
  ListDataCatalogsCommand,
  GetDataCatalogCommand,
  ListDatabasesCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type QueryExecution,
  type NamedQuery,
} from '@aws-sdk/client-athena';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, accountId } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new AthenaClient({ region: r, credentials: cachedCredentials(p) });

const QUERY_LIMIT = 50;
const bytes = (b?: number) => (b === undefined ? undefined : b >= 1e9 ? `${(b / 1e9).toFixed(2)} GB` : b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.round(b / 1e3)} KB`);
const oneLine = (q?: string, n = 160) => (q ? q.replace(/\s+/g, ' ').trim().slice(0, n) + (q.length > n ? '…' : '') : undefined);

async function recentQueries(c: AthenaClient, workGroup: string): Promise<QueryExecution[]> {
  const ids = (await c.send(new ListQueryExecutionsCommand({ WorkGroup: workGroup, MaxResults: QUERY_LIMIT }))).QueryExecutionIds || [];
  if (!ids.length) return [];
  return ((await c.send(new BatchGetQueryExecutionCommand({ QueryExecutionIds: ids }))).QueryExecutions || []).sort(
    (a, b) => (b.Status?.SubmissionDateTime?.getTime() ?? 0) - (a.Status?.SubmissionDateTime?.getTime() ?? 0),
  );
}

async function namedQueries(c: AthenaClient, workGroup: string): Promise<NamedQuery[]> {
  const ids = await pageAll((NextToken) => c.send(new ListNamedQueriesCommand({ WorkGroup: workGroup, NextToken })), (r) => r.NamedQueryIds, (r) => r.NextToken, 200);
  const out: NamedQuery[] = [];
  for (let i = 0; i < ids.length; i += 50) out.push(...((await c.send(new BatchGetNamedQueryCommand({ NamedQueryIds: ids.slice(i, i + 50) }))).NamedQueries || []));
  return out.sort((a, b) => (a.Name || '').localeCompare(b.Name || ''));
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [groups, catalogs] = await Promise.all([
    pageAll((NextToken) => c.send(new ListWorkGroupsCommand({ NextToken })), (r) => r.WorkGroups, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListDataCatalogsCommand({ NextToken })), (r) => r.DataCatalogsSummary, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...groups.map((g) => ({ id: `wg:${g.Name}`, name: g.Name || '', group: 'Workgroups', status: g.State, info: [g.EngineVersion?.EffectiveEngineVersion, g.Description].filter(Boolean).join(' · ') })).sort((a, b) => a.name.localeCompare(b.name)),
    ...catalogs.map((x) => ({ id: `cat:${x.CatalogName}`, name: x.CatalogName || '', group: 'Data catalogs', info: x.Type })),
  ];
}

async function workGroupPage(c: AthenaClient, profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const g = (await c.send(new GetWorkGroupCommand({ WorkGroup: name }))).WorkGroup;
  if (!g) throw httpError(`Workgroup not found: ${name}`, 404);
  const arn = `arn:aws:athena:${region}:${await accountId(profile, region)}:workgroup/${name}`;
  const errors: string[] = [];
  const parts = await settle({ queries: recentQueries(c, name), saved: namedQueries(c, name), tags: c.send(new ListTagsForResourceCommand({ ResourceARN: arn })) }, errors);
  const cfg = g.Configuration;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Workgroup', [
          ['Name', g.Name],
          ['State', g.State],
          ['Description', g.Description],
          ['Engine', cfg?.EngineVersion?.EffectiveEngineVersion],
          ['Query result location', cfg?.ResultConfiguration?.OutputLocation],
          ['Result encryption', cfg?.ResultConfiguration?.EncryptionConfiguration?.EncryptionOption],
          ['Enforce workgroup settings', cfg?.EnforceWorkGroupConfiguration],
          ['Per-query scan limit', bytes(cfg?.BytesScannedCutoffPerQuery)],
          ['CloudWatch metrics', cfg?.PublishCloudWatchMetricsEnabled],
          ['Requester pays', cfg?.RequesterPaysEnabled],
          ['Execution role', cfg?.ExecutionRole],
          ['Identity Center', g.IdentityCenterApplicationArn],
          ['Created', g.CreationTime],
        ]),
      ],
    }),
    tab('Recent queries', {
      tables: [
        table(
          ['Submitted', 'State', 'Type', 'Database', 'Data scanned', 'Run time', 'Query'],
          (parts.queries || []).map((q) => [
            q.Status?.SubmissionDateTime,
            q.Status?.State,
            q.StatementType,
            q.QueryExecutionContext?.Database,
            bytes(q.Statistics?.DataScannedInBytes),
            q.Statistics?.TotalExecutionTimeInMillis !== undefined ? `${(q.Statistics.TotalExecutionTimeInMillis / 1000).toFixed(1)} s` : undefined,
            oneLine(q.Query),
          ]),
          { statusColumn: 1, title: `Last ${QUERY_LIMIT} queries`, emptyMessage: 'No queries in the last 45 days' },
        ),
      ],
    }),
    tab('Saved queries', {
      tables: [table(['Name', 'Database', 'Description', 'Query'], (parts.saved || []).map((q) => [q.Name, q.Database, q.Description, oneLine(q.QueryString)]), { emptyMessage: 'No saved queries' })],
    }),
  ];
  const failed = (parts.queries || []).find((q) => q.Status?.State === 'FAILED');
  if (failed?.Status?.StateChangeReason) {
    tabs[0].sections.push(section('Most recent failure', [['Query', oneLine(failed.Query, 300)], ['Reason', failed.Status.StateChangeReason], ['When', failed.Status.CompletionDateTime]]));
  }
  return { id, title: name, subtitle: g.Description || 'Athena workgroup', status: g.State, arn, tabs, tags: tagList(parts.tags?.Tags), actions: [], errors };
}

async function catalogPage(c: AthenaClient, profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const d = (await c.send(new GetDataCatalogCommand({ Name: name }))).DataCatalog;
  if (!d) throw httpError(`Data catalog not found: ${name}`, 404);
  const arn = `arn:aws:athena:${region}:${await accountId(profile, region)}:datacatalog/${name}`;
  const errors: string[] = [];
  const parts = await settle(
    {
      databases: pageAll((NextToken) => c.send(new ListDatabasesCommand({ CatalogName: name, NextToken })), (r) => r.DatabaseList, (r) => r.NextToken, 500),
      // The built-in AwsDataCatalog can't be tagged.
      tags: name === 'AwsDataCatalog' ? Promise.resolve(undefined) : c.send(new ListTagsForResourceCommand({ ResourceARN: arn })),
    },
    errors,
  );
  return {
    id,
    title: name,
    subtitle: `${d.Type} data catalog`,
    arn: name === 'AwsDataCatalog' ? undefined : arn,
    tabs: [
      tab('Details', {
        sections: [section('Catalog', [['Name', d.Name], ['Type', d.Type], ['Description', d.Description]])],
        tables: [table(['Parameter', 'Value'], Object.entries(d.Parameters || {}), { title: 'Parameters', emptyMessage: 'No parameters' })],
      }),
      tab('Databases', {
        tables: [table(['Database', 'Description'], (parts.databases || []).map((x) => [x.Name, x.Description]), { emptyMessage: 'No databases' })],
      }),
    ],
    tags: name === 'AwsDataCatalog' ? undefined : tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  if (kind === 'wg') return workGroupPage(c, profile, region, id, name);
  if (kind === 'cat') return catalogPage(c, profile, region, id, name);
  throw httpError(`Unknown Athena page: ${id}`, 400);
}

export const athenaAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('This resource has no tags', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('This resource has no tags', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('wg:'),
};
