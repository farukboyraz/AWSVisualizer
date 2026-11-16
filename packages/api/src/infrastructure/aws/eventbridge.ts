import {
  EventBridgeClient,
  ListEventBusesCommand,
  DescribeEventBusCommand,
  ListRulesCommand,
  DescribeRuleCommand,
  ListTargetsByRuleCommand,
  ListApiDestinationsCommand,
  DescribeApiDestinationCommand,
  ListConnectionsCommand,
  DescribeConnectionCommand,
  ListArchivesCommand,
  DescribeArchiveCommand,
  ListTagsForResourceCommand as EbListTags,
  TagResourceCommand as EbTag,
  UntagResourceCommand as EbUntag,
  type Target,
} from '@aws-sdk/client-eventbridge';
import { SchedulerClient, ListSchedulesCommand, GetScheduleCommand } from '@aws-sdk/client-scheduler';
import type { PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart, mapLimited, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Header / parameter names whose values are never shown. */
const SECRET_KEY = /authorization|pass(word)?|secret|token|credential|api.?key|\bkey\b/i;
const pretty = (s?: string) => {
  if (!s) return undefined;
  try {
    return JSON.stringify(JSON.parse(s), null, 2);
  } catch {
    return s;
  }
};
/** `a|b` compound ids. */
const pair = (rest: string) => {
  const i = rest.indexOf('|');
  if (i < 0) throw httpError(`Bad id: ${rest}`, 400);
  return [rest.slice(0, i), rest.slice(i + 1)] as const;
};

/** EventBridge (+ Scheduler). */
const eb = (p: string, r: string) => new EventBridgeClient(clientConfig(p, r));
const sch = (p: string, r: string) => new SchedulerClient(clientConfig(p, r));

/** One line per target: where it goes, plus the input shape (header values with secret names masked). */
const targetRow = (t: Target) => [
  t.Id,
  t.Arn,
  t.Input ? 'Constant JSON' : t.InputPath ? `Path ${t.InputPath}` : t.InputTransformer ? 'Input transformer' : 'Matched event',
  Object.entries(t.HttpParameters?.HeaderParameters || {}).map(([k, v]) => `${k}: ${SECRET_KEY.test(k) ? '••••' : v}`),
  t.RetryPolicy ? `${t.RetryPolicy.MaximumRetryAttempts ?? '-'} retries / ${t.RetryPolicy.MaximumEventAgeInSeconds ?? '-'} s` : undefined,
  t.DeadLetterConfig?.Arn,
];

export const eventBridgeAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = eb(profile, region);
    const [buses, dests, conns, archives, schedules] = await Promise.all([
      pageAll((NextToken) => c.send(new ListEventBusesCommand({ NextToken })), (r) => r.EventBuses, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListApiDestinationsCommand({ NextToken })), (r) => r.ApiDestinations, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListConnectionsCommand({ NextToken })), (r) => r.Connections, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListArchivesCommand({ NextToken })), (r) => r.Archives, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => sch(profile, region).send(new ListSchedulesCommand({ NextToken })), (r) => r.Schedules, (r) => r.NextToken).catch(() => []),
    ]);
    const rules = (await mapLimited(buses, 4, (b) => pageAll((NextToken) => c.send(new ListRulesCommand({ EventBusName: b.Name, NextToken })), (r) => r.Rules, (r) => r.NextToken).catch(() => []))).flat();
    return [
      ...buses.map((b) => ({ id: `bus:${b.Name}`, name: b.Name || '', group: 'Event buses', info: b.Description || (b.Name === 'default' ? 'AWS service events' : undefined) })).sort(byName),
      ...rules.map((r) => ({ id: `rule:${r.EventBusName}|${r.Name}`, name: r.Name || '', group: 'Rules', status: r.State, info: [r.EventBusName !== 'default' && `bus ${r.EventBusName}`, r.ScheduleExpression ?? 'event pattern', r.ManagedBy && `managed by ${r.ManagedBy}`].filter(Boolean).join(' · ') })).sort(byName),
      ...schedules.map((s) => ({ id: `sch:${s.GroupName}|${s.Name}`, name: s.Name || '', group: 'Scheduler schedules', status: s.State, info: [s.GroupName !== 'default' && `group ${s.GroupName}`, lastPart(s.Target?.Arn)].filter(Boolean).join(' · ') })).sort(byName),
      ...dests.map((d) => ({ id: `dest:${d.Name}`, name: d.Name || '', group: 'API destinations', status: d.ApiDestinationState, info: `${d.HttpMethod} ${d.InvocationEndpoint ?? ''}` })).sort(byName),
      ...conns.map((x) => ({ id: `conn:${x.Name}`, name: x.Name || '', group: 'Connections', status: x.ConnectionState, info: x.AuthorizationType })).sort(byName),
      ...archives.map((a) => ({ id: `arch:${a.ArchiveName}`, name: a.ArchiveName || '', group: 'Archives', status: a.State, info: `${a.EventCount ?? 0} events` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = eb(profile, region);
    const [kind, rest] = splitId(id);
    const errors: string[] = [];
    const tags = async (arn?: string) => (arn ? (await settle({ t: c.send(new EbListTags({ ResourceARN: arn })) }, errors)).t?.Tags : undefined);
    if (kind === 'bus') {
      const b = await c.send(new DescribeEventBusCommand({ Name: rest }));
      const [rules, t] = await Promise.all([pageAll((NextToken) => c.send(new ListRulesCommand({ EventBusName: rest, NextToken })), (r) => r.Rules, (r) => r.NextToken).catch(() => []), tags(b.Arn)]);
      const tabs: PageTab[] = [
        tab('Details', {
          sections: [section('Event bus', [['Name', b.Name], ['Description', b.Description], ['Dead-letter queue', b.DeadLetterConfig?.Arn], ['KMS key', b.KmsKeyIdentifier], ['Created', b.CreationTime], ['Modified', b.LastModifiedTime]])],
          tables: [table(['Rule', 'State', 'Type', 'Description'], rules.map((r) => [r.Name, r.State, r.ScheduleExpression ? `Schedule ${r.ScheduleExpression}` : 'Event pattern', r.Description]), { title: 'Rules', statusColumn: 1, emptyMessage: 'No rules' })],
        }),
      ];
      if (pretty(b.Policy)) tabs.push(tab('Resource policy', { json: pretty(b.Policy) }));
      return { id, title: rest, subtitle: 'Event bus', arn: b.Arn, tabs, tags: tagList(t), actions: [], errors };
    }
    if (kind === 'rule') {
      const [bus, name] = pair(rest);
      const r = await c.send(new DescribeRuleCommand({ EventBusName: bus, Name: name }));
      const [targets, t] = await Promise.all([pageAll((NextToken) => c.send(new ListTargetsByRuleCommand({ EventBusName: bus, Rule: name, NextToken })), (x) => x.Targets, (x) => x.NextToken).catch(() => []), tags(r.Arn)]);
      const tabs: PageTab[] = [
        tab('Details', {
          sections: [section('Rule', [['Event bus', r.EventBusName], ['State', r.State], ['Description', r.Description], ['Schedule', r.ScheduleExpression], ['Role', r.RoleArn], ['Managed by', r.ManagedBy], ['Created by', r.CreatedBy]])],
          tables: [table(['Target ID', 'Target', 'Input', 'HTTP headers', 'Retry', 'Dead-letter queue'], targets.map(targetRow), { title: 'Targets', emptyMessage: 'No targets' })],
        }),
      ];
      if (pretty(r.EventPattern)) tabs.push(tab('Event pattern', { json: pretty(r.EventPattern) }));
      return { id, title: name, subtitle: `Rule on ${bus}`, status: r.State, arn: r.Arn, tabs, tags: tagList(t), actions: [], errors };
    }
    if (kind === 'sch') {
      const [group, name] = pair(rest);
      const s = await sch(profile, region).send(new GetScheduleCommand({ GroupName: group, Name: name }));
      return {
        id,
        title: name,
        subtitle: `Schedule in ${group}`,
        status: s.State,
        arn: s.Arn,
        tabs: [
          tab('Details', {
            sections: [
              section('Schedule', [
                ['Expression', s.ScheduleExpression],
                ['Time zone', s.ScheduleExpressionTimezone],
                ['Flexible window', s.FlexibleTimeWindow?.Mode === 'FLEXIBLE' ? `${s.FlexibleTimeWindow.MaximumWindowInMinutes} min` : 'Off'],
                ['Start', s.StartDate],
                ['End', s.EndDate],
                ['After completion', s.ActionAfterCompletion],
                ['Description', s.Description],
                ['KMS key', s.KmsKeyArn],
                ['Created', s.CreationDate],
                ['Modified', s.LastModificationDate],
              ]),
              section('Target', [['Target', s.Target?.Arn], ['Role', s.Target?.RoleArn], ['Retries', s.Target?.RetryPolicy?.MaximumRetryAttempts], ['Dead-letter queue', s.Target?.DeadLetterConfig?.Arn]]),
            ],
          }),
        ],
        actions: [],
        errors,
      };
    }
    if (kind === 'dest') {
      const d = await c.send(new DescribeApiDestinationCommand({ Name: rest }));
      return {
        id,
        title: rest,
        subtitle: 'API destination',
        status: d.ApiDestinationState,
        arn: d.ApiDestinationArn,
        tabs: [tab('Details', { sections: [section('API destination', [['Endpoint', d.InvocationEndpoint], ['Method', d.HttpMethod], ['Rate limit (per second)', d.InvocationRateLimitPerSecond], ['Connection', lastPart(d.ConnectionArn)], ['Description', d.Description], ['Created', d.CreationTime], ['Modified', d.LastModifiedTime]])] })],
        actions: [],
        errors,
      };
    }
    if (kind === 'conn') {
      // Credentials live in the connection's Secrets Manager secret; only names / types are shown.
      const x = await c.send(new DescribeConnectionCommand({ Name: rest }));
      const a = x.AuthParameters;
      const extra = [
        ...(a?.InvocationHttpParameters?.HeaderParameters || []).map((h) => ['Header', h.Key, h.IsValueSecret || SECRET_KEY.test(h.Key || '') ? '••••' : h.Value]),
        ...(a?.InvocationHttpParameters?.QueryStringParameters || []).map((h) => ['Query', h.Key, h.IsValueSecret || SECRET_KEY.test(h.Key || '') ? '••••' : h.Value]),
        ...(a?.InvocationHttpParameters?.BodyParameters || []).map((h) => ['Body', h.Key, h.IsValueSecret || SECRET_KEY.test(h.Key || '') ? '••••' : h.Value]),
      ];
      return {
        id,
        title: rest,
        subtitle: `${x.AuthorizationType ?? ''} connection`,
        status: x.ConnectionState,
        arn: x.ConnectionArn,
        tabs: [
          tab('Details', {
            sections: [
              section('Connection', [
                ['State', x.ConnectionState],
                ['State reason', x.StateReason],
                ['Authorization', x.AuthorizationType],
                ['API key header', a?.ApiKeyAuthParameters?.ApiKeyName],
                ['Basic auth user', a?.BasicAuthParameters?.Username],
                ['OAuth endpoint', a?.OAuthParameters?.AuthorizationEndpoint],
                ['OAuth client ID', a?.OAuthParameters?.ClientParameters?.ClientID],
                ['Credentials secret', x.SecretArn],
                ['Description', x.Description],
                ['Last authorized', x.LastAuthorizedTime],
                ['Created', x.CreationTime],
              ]),
            ],
            tables: [table(['In', 'Name', 'Value'], extra, { title: 'Extra invocation parameters', emptyMessage: 'None' })],
          }),
        ],
        actions: [],
        errors,
      };
    }
    if (kind === 'arch') {
      const a = await c.send(new DescribeArchiveCommand({ ArchiveName: rest }));
      const tabs: PageTab[] = [tab('Details', { sections: [section('Archive', [['Source', a.EventSourceArn], ['State', a.State], ['State reason', a.StateReason], ['Retention (days)', a.RetentionDays || 'Indefinite'], ['Events', a.EventCount], ['Size (bytes)', a.SizeBytes], ['Description', a.Description], ['Created', a.CreationTime]])] })];
      if (pretty(a.EventPattern)) tabs.push(tab('Event pattern', { json: pretty(a.EventPattern) }));
      return { id, title: rest, subtitle: 'Event archive', status: a.State, arn: a.ArchiveArn, tabs, actions: [], errors };
    }
    throw httpError(`Unknown EventBridge page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !(id.startsWith('bus:') || id.startsWith('rule:'))) throw httpError('Only event buses and rules can be tagged here', 400);
    await eb(profile, region).send(new EbTag({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !(id.startsWith('bus:') || id.startsWith('rule:'))) throw httpError('Only event buses and rules can be tagged here', 400);
    await eb(profile, region).send(new EbUntag({ ResourceARN: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('rule:') || row.id.startsWith('sch:'),
};
