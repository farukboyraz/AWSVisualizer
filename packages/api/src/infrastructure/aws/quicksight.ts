import {
  QuickSightClient,
  DescribeAccountSubscriptionCommand,
  ListDashboardsCommand,
  DescribeDashboardCommand,
  DescribeDashboardPermissionsCommand,
  ListAnalysesCommand,
  DescribeAnalysisCommand,
  ListDataSetsCommand,
  DescribeDataSetCommand,
  ListIngestionsCommand,
  ListDataSourcesCommand,
  DescribeDataSourceCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-quicksight';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, accountId, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new QuickSightClient({ region: r, credentials: cachedCredentials(p) });

const errName = (err: unknown) => (err as { name?: string })?.name;
/** Not signed up for QuickSight (or not in this region): an empty list. */
const notSubscribed = (err: unknown) => ['ResourceNotFoundException', 'UnsupportedUserEditionException', 'AccessDeniedException'].includes(errName(err) || '');
const bytes = (b?: number) => (b === undefined ? undefined : b >= 1e9 ? `${(b / 1e9).toFixed(2)} GB` : `${(b / 1e6).toFixed(1)} MB`);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const AwsAccountId = await accountId(profile, region);
  const c = client(profile, region);
  let account;
  try {
    account = (await c.send(new DescribeAccountSubscriptionCommand({ AwsAccountId }))).AccountInfo;
  } catch (err) {
    if (notSubscribed(err)) return [];
    throw err;
  }
  const [dashboards, analyses, dataSets, dataSources] = await Promise.all([
    pageAll((NextToken) => c.send(new ListDashboardsCommand({ AwsAccountId, NextToken })), (r) => r.DashboardSummaryList, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListAnalysesCommand({ AwsAccountId, NextToken })), (r) => r.AnalysisSummaryList, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListDataSetsCommand({ AwsAccountId, NextToken })), (r) => r.DataSetSummaries, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListDataSourcesCommand({ AwsAccountId, NextToken })), (r) => r.DataSources, (r) => r.NextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    { id: 'acct:', name: account?.AccountName || 'QuickSight account', group: 'Account', status: account?.AccountSubscriptionStatus, info: [account?.Edition, account?.AuthenticationType].filter(Boolean).join(' · ') },
    ...dashboards.map((d) => ({ id: `dash:${d.DashboardId}`, name: d.Name || '', group: 'Dashboards', info: `v${d.PublishedVersionNumber ?? '-'} · published ${d.LastPublishedTime?.toISOString().slice(0, 10) ?? '-'}` })).sort(byName),
    ...analyses.filter((a) => a.Status !== 'DELETED').map((a) => ({ id: `an:${a.AnalysisId}`, name: a.Name || '', group: 'Analyses', status: a.Status })).sort(byName),
    ...dataSets.map((d) => ({ id: `set:${d.DataSetId}`, name: d.Name || '', group: 'Datasets', info: d.ImportMode })).sort(byName),
    ...dataSources.map((d) => ({ id: `src:${d.DataSourceId}`, name: d.Name || '', group: 'Data sources', status: d.Status, info: d.Type })).sort(byName),
  ];
}

async function accountPage(c: QuickSightClient, AwsAccountId: string, id: string): Promise<ResourcePage> {
  const a = (await c.send(new DescribeAccountSubscriptionCommand({ AwsAccountId }))).AccountInfo;
  return {
    id,
    title: a?.AccountName || 'QuickSight',
    subtitle: `${a?.Edition ?? ''} edition`,
    status: a?.AccountSubscriptionStatus,
    tabs: [tab('Account', { sections: [section('Subscription', [['Account name', a?.AccountName], ['Edition', a?.Edition], ['Status', a?.AccountSubscriptionStatus], ['Authentication', a?.AuthenticationType], ['Notification email', a?.NotificationEmail], ['Identity Center', a?.IAMIdentityCenterInstanceArn]])] })],
    actions: [],
    errors: [],
  };
}

const permissionsTable = (perms?: { Principal?: string; Actions?: string[] }[]) =>
  table(['Principal', 'Actions'], (perms || []).map((p) => [lastPart(p.Principal) ?? p.Principal, (p.Actions || []).map((x) => x.replace('quicksight:', '')).join(', ')]), { title: 'Permissions', emptyMessage: 'No explicit permissions' });

async function dashboardPage(c: QuickSightClient, AwsAccountId: string, id: string, dashboardId: string): Promise<ResourcePage> {
  const d = (await c.send(new DescribeDashboardCommand({ AwsAccountId, DashboardId: dashboardId }))).Dashboard;
  if (!d) throw httpError(`Dashboard not found: ${dashboardId}`, 404);
  const errors: string[] = [];
  const parts = await settle({ perms: c.send(new DescribeDashboardPermissionsCommand({ AwsAccountId, DashboardId: dashboardId })), tags: c.send(new ListTagsForResourceCommand({ ResourceArn: d.Arn })) }, errors);
  const v = d.Version;
  return {
    id,
    title: d.Name || dashboardId,
    subtitle: `Dashboard · version ${v?.VersionNumber ?? '-'}`,
    status: v?.Status,
    arn: d.Arn,
    tabs: [
      tab('Details', {
        sections: [section('Dashboard', [['Dashboard ID', d.DashboardId], ['Version', v?.VersionNumber], ['Status', v?.Status], ['Description', v?.Description], ['Source analysis', lastPart(v?.SourceEntityArn)], ['Theme', lastPart(v?.ThemeArn)], ['Created', d.CreatedTime], ['Published', d.LastPublishedTime], ['Updated', d.LastUpdatedTime]])],
        tables: [
          table(['Sheet', 'Sheet ID'], (v?.Sheets || []).map((s) => [s.Name, s.SheetId]), { title: 'Sheets', emptyMessage: 'No sheets' }),
          table(['Dataset'], (v?.DataSetArns || []).map((a) => [lastPart(a)]), { title: 'Datasets', emptyMessage: 'No datasets' }),
          table(['Type', 'Message'], (v?.Errors || []).map((e) => [e.Type, e.Message]), { title: 'Errors', emptyMessage: 'No errors' }),
        ],
      }),
      tab('Permissions', { tables: [permissionsTable(parts.perms?.Permissions)] }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function analysisPage(c: QuickSightClient, AwsAccountId: string, id: string, analysisId: string): Promise<ResourcePage> {
  const a = (await c.send(new DescribeAnalysisCommand({ AwsAccountId, AnalysisId: analysisId }))).Analysis;
  if (!a) throw httpError(`Analysis not found: ${analysisId}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ ResourceArn: a.Arn })) }, errors);
  return {
    id,
    title: a.Name || analysisId,
    subtitle: 'Analysis',
    status: a.Status,
    arn: a.Arn,
    tabs: [
      tab('Details', {
        sections: [section('Analysis', [['Analysis ID', a.AnalysisId], ['Status', a.Status], ['Theme', lastPart(a.ThemeArn)], ['Created', a.CreatedTime], ['Updated', a.LastUpdatedTime]])],
        tables: [
          table(['Sheet'], (a.Sheets || []).map((s) => [s.Name]), { title: 'Sheets', emptyMessage: 'No sheets' }),
          table(['Dataset'], (a.DataSetArns || []).map((x) => [lastPart(x)]), { title: 'Datasets', emptyMessage: 'No datasets' }),
          table(['Type', 'Message'], (a.Errors || []).map((e) => [e.Type, e.Message]), { title: 'Errors', emptyMessage: 'No errors' }),
        ],
      }),
    ],
    tags: tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

async function dataSetPage(c: QuickSightClient, AwsAccountId: string, id: string, dataSetId: string): Promise<ResourcePage> {
  const d = (await c.send(new DescribeDataSetCommand({ AwsAccountId, DataSetId: dataSetId }))).DataSet;
  if (!d) throw httpError(`Dataset not found: ${dataSetId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      ingestions: d.ImportMode === 'SPICE' ? c.send(new ListIngestionsCommand({ AwsAccountId, DataSetId: dataSetId, MaxResults: 25 })) : Promise.resolve(undefined),
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: d.Arn })),
    },
    errors,
  );
  const tables = Object.entries(d.PhysicalTableMap || {}).map(([k, t]) => {
    const src = t.RelationalTable ?? t.CustomSql ?? t.S3Source;
    const kind = t.RelationalTable ? 'Table' : t.CustomSql ? 'Custom SQL' : t.S3Source ? 'S3' : 'Other';
    const name = t.RelationalTable ? [t.RelationalTable.Catalog, t.RelationalTable.Schema, t.RelationalTable.Name].filter(Boolean).join('.') : t.CustomSql?.Name ?? '-';
    return [k, kind, name, lastPart((src as { DataSourceArn?: string } | undefined)?.DataSourceArn)];
  });
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Dataset', [
          ['Dataset ID', d.DataSetId],
          ['Import mode', d.ImportMode],
          ['SPICE size', bytes(d.ConsumedSpiceCapacityInBytes)],
          ['Row-level security', d.RowLevelPermissionDataSet ? lastPart(d.RowLevelPermissionDataSet.Arn) : undefined],
          ['Column-level rules', d.ColumnLevelPermissionRules?.length],
          ['Created', d.CreatedTime],
          ['Updated', d.LastUpdatedTime],
        ]),
      ],
      tables: [table(['Key', 'Kind', 'Source table', 'Data source'], tables, { title: 'Physical tables', emptyMessage: 'No tables' })],
    }),
    tab('Columns', {
      tables: [table(['Column', 'Type', 'Description'], (d.OutputColumns || []).map((x) => [x.Name, x.Type, x.Description]), { emptyMessage: 'No columns' })],
    }),
  ];
  if (d.ImportMode === 'SPICE') {
    tabs.push(
      tab('Refreshes', {
        tables: [
          table(['Ingestion', 'Status', 'Started', 'Time (s)', 'Rows ingested', 'Rows dropped', 'Error'], (parts.ingestions?.Ingestions || []).map((i) => [i.IngestionId, i.IngestionStatus, i.CreatedTime, i.IngestionTimeInSeconds, i.RowInfo?.RowsIngested, i.RowInfo?.RowsDropped, i.ErrorInfo?.Message]), {
            statusColumn: 1,
            title: 'Last 25 SPICE refreshes',
            emptyMessage: 'No refreshes',
          }),
        ],
      }),
    );
  }
  return { id, title: d.Name || dataSetId, subtitle: `${d.ImportMode ?? ''} dataset`, arn: d.Arn, tabs, tags: tagList(parts.tags?.Tags), actions: [], errors };
}

async function dataSourcePage(c: QuickSightClient, AwsAccountId: string, id: string, dataSourceId: string): Promise<ResourcePage> {
  const d = (await c.send(new DescribeDataSourceCommand({ AwsAccountId, DataSourceId: dataSourceId }))).DataSource;
  if (!d) throw httpError(`Data source not found: ${dataSourceId}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ ResourceArn: d.Arn })) }, errors);
  // Connection parameters (host, port, database…) - QuickSight never returns credentials.
  const params = Object.entries(d.DataSourceParameters || {})[0];
  return {
    id,
    title: d.Name || dataSourceId,
    subtitle: `${d.Type ?? ''} data source`,
    status: d.Status,
    arn: d.Arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Data source', [
            ['Type', d.Type],
            ['Status', d.Status],
            ['Credentials secret', d.SecretArn],
            ['VPC connection', lastPart(d.VpcConnectionProperties?.VpcConnectionArn)],
            ['SSL', d.SslProperties?.DisableSsl === true ? 'Disabled' : 'Enabled'],
            ['Error', d.ErrorInfo?.Message],
            ['Created', d.CreatedTime],
            ['Updated', d.LastUpdatedTime],
          ]),
          ...(params ? [section(`Connection (${params[0].replace(/Parameters$/, '')})`, Object.entries(params[1] || {}).filter(([, v]) => typeof v !== 'object') as [string, unknown][])] : []),
        ],
      }),
    ],
    tags: tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (!['acct', 'dash', 'an', 'set', 'src'].includes(kind)) throw httpError(`Unknown QuickSight page: ${id}`, 400);
  const c = client(profile, region);
  const AwsAccountId = await accountId(profile, region);
  if (kind === 'acct') return accountPage(c, AwsAccountId, id);
  if (kind === 'dash') return dashboardPage(c, AwsAccountId, id, rest);
  if (kind === 'an') return analysisPage(c, AwsAccountId, id, rest);
  if (kind === 'set') return dataSetPage(c, AwsAccountId, id, rest);
  return dataSourcePage(c, AwsAccountId, id, rest);
}

export const quickSightAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || id === 'acct:') throw httpError('The account page has no tags', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || id === 'acct:') throw httpError('The account page has no tags', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('dash:'),
};
