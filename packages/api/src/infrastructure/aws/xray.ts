import {
  XRayClient,
  GetServiceGraphCommand,
  GetTraceSummariesCommand,
  GetGroupsCommand,
  GetGroupCommand,
  GetSamplingRulesCommand,
  GetEncryptionConfigCommand,
  GetInsightSummariesCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Service,
} from '@aws-sdk/client-xray';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new XRayClient({ region: r, credentials: cachedCredentials(p) });

const HOUR = 3_600_000;
const TRACE_LIMIT = 100;
const ms = (s?: number) => (s === undefined ? undefined : `${Math.round(s * 1000)} ms`);
const lastHour = () => ({ StartTime: new Date(Date.now() - HOUR), EndTime: new Date() });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [groups, rules] = await Promise.all([
    pageAll((NextToken) => c.send(new GetGroupsCommand({ NextToken })), (r) => r.Groups, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new GetSamplingRulesCommand({ NextToken })), (r) => r.SamplingRuleRecords, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    { id: 'graph:', name: 'Service map', group: 'Last hour', info: 'Services, requests, errors and latency' },
    { id: 'traces:', name: 'Traces', group: 'Last hour', info: `Most recent ${TRACE_LIMIT} trace summaries` },
    ...groups.map((g) => ({ id: `grp:${g.GroupName}`, name: g.GroupName || '', group: 'Groups', info: g.FilterExpression || 'All traces' })),
    ...rules
      .map((r) => r.SamplingRule)
      .filter(Boolean)
      .sort((a, b) => (a!.Priority ?? 0) - (b!.Priority ?? 0))
      .map((r) => ({ id: `rule:${r!.RuleName}`, name: r!.RuleName || '', group: 'Sampling rules', info: `priority ${r!.Priority} · ${Math.round((r!.FixedRate ?? 0) * 100)}% + ${r!.ReservoirSize}/s` })),
  ];
}

const stats = (s: Service) => {
  const st = s.SummaryStatistics;
  const total = st?.TotalCount ?? 0;
  const pct = (n?: number) => (total ? `${(((n ?? 0) / total) * 100).toFixed(1)}%` : '-');
  return [s.Name, s.Type, total, pct(st?.ErrorStatistics?.TotalCount), pct(st?.FaultStatistics?.TotalCount), ms(total ? (st?.TotalResponseTime ?? 0) / total : undefined), (s.Edges || []).length];
};

async function graphPage(c: XRayClient): Promise<ResourcePage> {
  const errors: string[] = [];
  const parts = await settle(
    {
      services: pageAll((NextToken) => c.send(new GetServiceGraphCommand({ ...lastHour(), NextToken })), (r) => r.Services, (r) => r.NextToken),
      encryption: c.send(new GetEncryptionConfigCommand({})),
    },
    errors,
  );
  const services = (parts.services || []).sort((a, b) => (b.SummaryStatistics?.TotalCount ?? 0) - (a.SummaryStatistics?.TotalCount ?? 0));
  const names = new Map(services.map((s) => [s.ReferenceId, s.Name]));
  const enc = parts.encryption?.EncryptionConfig;
  return {
    id: 'graph:',
    title: 'Service map',
    subtitle: 'Last hour',
    tabs: [
      tab('Services', {
        tables: [table(['Service', 'Type', 'Requests', 'Errors (4xx)', 'Faults (5xx)', 'Avg latency', 'Downstream'], services.map(stats), { emptyMessage: 'No traced requests in the last hour' })],
      }),
      tab('Connections', {
        tables: [
          table(
            ['From', 'To', 'Requests', 'Avg latency'],
            services.flatMap((s) => (s.Edges || []).map((e) => [s.Name, names.get(e.ReferenceId) ?? e.ReferenceId, e.SummaryStatistics?.TotalCount, ms(e.SummaryStatistics?.TotalCount ? (e.SummaryStatistics.TotalResponseTime ?? 0) / e.SummaryStatistics.TotalCount : undefined)])),
            { emptyMessage: 'No connections' },
          ),
        ],
      }),
      tab('Settings', { sections: [section('Encryption', [['Type', enc?.Type], ['KMS key', enc?.KeyId], ['Status', enc?.Status]])] }),
    ],
    actions: [],
    errors,
  };
}

async function tracesPage(c: XRayClient): Promise<ResourcePage> {
  const traces = await pageAll((NextToken) => c.send(new GetTraceSummariesCommand({ ...lastHour(), NextToken, Sampling: false })), (r) => r.TraceSummaries, (r) => r.NextToken, TRACE_LIMIT);
  const rows = traces.slice(0, TRACE_LIMIT).sort((a, b) => (b.StartTime?.getTime() ?? 0) - (a.StartTime?.getTime() ?? 0));
  return {
    id: 'traces:',
    title: 'Traces',
    subtitle: 'Last hour',
    tabs: [
      tab('Traces', {
        tables: [
          table(
            ['Started', 'Method', 'URL', 'Status', 'Response time', 'Entry point', 'Issue', 'Trace ID'],
            rows.map((t) => [t.StartTime, t.Http?.HttpMethod, t.Http?.HttpURL, t.Http?.HttpStatus, ms(t.ResponseTime), t.EntryPoint?.Name, t.HasFault ? 'Fault' : t.HasError ? 'Error' : t.HasThrottle ? 'Throttle' : undefined, t.Id]),
            { title: `Most recent ${TRACE_LIMIT}`, emptyMessage: 'No traces in the last hour' },
          ),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function groupPage(c: XRayClient, id: string, name: string): Promise<ResourcePage> {
  const g = (await c.send(new GetGroupCommand({ GroupName: name }))).Group;
  if (!g) throw httpError(`Group not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      insights: g.InsightsConfiguration?.InsightsEnabled
        ? c.send(new GetInsightSummariesCommand({ GroupName: name, StartTime: new Date(Date.now() - 24 * HOUR), EndTime: new Date() }))
        : Promise.resolve(undefined),
      // The Default group has no taggable ARN.
      tags: g.GroupARN && name !== 'Default' ? c.send(new ListTagsForResourceCommand({ ResourceARN: g.GroupARN })) : Promise.resolve(undefined),
    },
    errors,
  );
  return {
    id,
    title: name,
    subtitle: 'X-Ray group',
    arn: name === 'Default' ? undefined : g.GroupARN,
    tabs: [
      tab('Details', {
        sections: [section('Group', [['Name', name], ['Filter expression', g.FilterExpression || 'All traces'], ['Insights', g.InsightsConfiguration?.InsightsEnabled], ['Insight notifications', g.InsightsConfiguration?.NotificationsEnabled]])],
      }),
      tab('Insights', {
        tables: [
          table(['Started', 'State', 'Root cause', 'Categories', 'Summary'], (parts.insights?.InsightSummaries || []).map((i) => [i.StartTime, i.State, i.RootCauseServiceId?.Name, i.Categories, i.Summary]), {
            statusColumn: 1,
            title: 'Last 24 hours',
            emptyMessage: g.InsightsConfiguration?.InsightsEnabled ? 'No insights' : 'Insights are off for this group',
          }),
        ],
      }),
    ],
    tags: name === 'Default' ? undefined : tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function rulePage(c: XRayClient, id: string, name: string): Promise<ResourcePage> {
  const rec = (await pageAll((NextToken) => c.send(new GetSamplingRulesCommand({ NextToken })), (r) => r.SamplingRuleRecords, (r) => r.NextToken)).find((x) => x.SamplingRule?.RuleName === name);
  const r = rec?.SamplingRule;
  if (!r) throw httpError(`Sampling rule not found: ${name}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: r.RuleARN && name !== 'Default' ? c.send(new ListTagsForResourceCommand({ ResourceARN: r.RuleARN })) : Promise.resolve(undefined) }, errors);
  return {
    id,
    title: name,
    subtitle: 'Sampling rule',
    arn: name === 'Default' ? undefined : r.RuleARN,
    tabs: [
      tab('Details', {
        sections: [
          section('Rule', [
            ['Priority', r.Priority],
            ['Reservoir (per second)', r.ReservoirSize],
            ['Fixed rate', `${Math.round((r.FixedRate ?? 0) * 100)}%`],
            ['Service name', r.ServiceName],
            ['Service type', r.ServiceType],
            ['Host', r.Host],
            ['HTTP method', r.HTTPMethod],
            ['URL path', r.URLPath],
            ['Resource ARN', r.ResourceARN],
            ['Attributes', Object.entries(r.Attributes || {}).map(([k, v]) => `${k}=${v}`)],
            ['Created', rec?.CreatedAt],
            ['Modified', rec?.ModifiedAt],
          ]),
        ],
      }),
    ],
    tags: name === 'Default' ? undefined : tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'graph') return graphPage(c);
  if (kind === 'traces') return tracesPage(c);
  if (kind === 'grp') return groupPage(c, id, rest);
  if (kind === 'rule') return rulePage(c, id, rest);
  throw httpError(`Unknown X-Ray page: ${id}`, 400);
}

function taggable(id: string, arn: string) {
  if (!arn || id.startsWith('graph:') || id.startsWith('traces:')) throw httpError('Only groups and sampling rules can be tagged (not Default)', 400);
  return arn;
}

export const xrayAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: taggable(id, arn), Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: taggable(id, arn), TagKeys: [key] }));
  },
  uncounted: true,
};
