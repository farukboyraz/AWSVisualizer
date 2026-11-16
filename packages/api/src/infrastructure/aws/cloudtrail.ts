import {
  CloudTrailClient,
  DescribeTrailsCommand,
  GetTrailStatusCommand,
  GetEventSelectorsCommand,
  GetInsightSelectorsCommand,
  ListTagsCommand,
  AddTagsCommand,
  RemoveTagsCommand,
  ListEventDataStoresCommand,
  GetEventDataStoreCommand,
  LookupEventsCommand,
  type Trail,
} from '@aws-sdk/client-cloudtrail';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, isNotEnabled } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new CloudTrailClient({ region: r, credentials: cachedCredentials(p) });

const EVENT_LIMIT = 100;

async function trails(c: CloudTrailClient): Promise<Trail[]> {
  return (await c.send(new DescribeTrailsCommand({ includeShadowTrails: true }))).trailList || [];
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [t, stores] = await Promise.all([
    trails(c),
    pageAll((NextToken) => c.send(new ListEventDataStoresCommand({ NextToken })), (r) => r.EventDataStores, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    { id: 'events:', name: 'Event history', group: 'Event history', info: `Last ${EVENT_LIMIT} management events in ${region}` },
    ...t
      .map((x) => ({
        id: `trail:${x.TrailARN}`,
        name: x.Name || '',
        group: 'Trails',
        info: [x.IsMultiRegionTrail ? 'Multi-region' : `Single region (${x.HomeRegion})`, x.IsOrganizationTrail && 'Organization trail', x.HomeRegion !== region && `home ${x.HomeRegion}`, `s3://${x.S3BucketName ?? '-'}`].filter(Boolean).join(' · '),
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    ...stores
      .filter((s) => s.Status !== 'PENDING_DELETION')
      .map((s) => ({ id: `eds:${s.EventDataStoreArn}`, name: s.Name || '', group: 'Lake event data stores', status: s.Status, info: s.MultiRegionEnabled ? 'Multi-region' : 'Single region' })),
  ];
}

async function eventsPage(c: CloudTrailClient, region: string): Promise<ResourcePage> {
  const events = await pageAll((NextToken) => c.send(new LookupEventsCommand({ NextToken, MaxResults: 50 })), (r) => r.Events, (r) => r.NextToken, EVENT_LIMIT);
  return {
    id: 'events:',
    title: 'Event history',
    subtitle: `Management events in ${region} (last 90 days)`,
    tabs: [
      tab('Events', {
        tables: [
          table(
            ['Time', 'Event', 'Source', 'User', 'Resources', 'Read only'],
            events.slice(0, EVENT_LIMIT).map((e) => [e.EventTime, e.EventName, e.EventSource, e.Username, (e.Resources || []).map((r) => r.ResourceName).filter(Boolean).slice(0, 3), e.ReadOnly]),
            { title: `Most recent ${EVENT_LIMIT} events`, emptyMessage: 'No events' },
          ),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function trailPage(profile: string, region: string, id: string, arn: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const t = (await trails(c)).find((x) => x.TrailARN === arn);
  if (!t) throw httpError(`Trail not found: ${arn}`, 404);
  const errors: string[] = [];
  // Status / selectors / tags are only answered by the trail's home region.
  const home = t.HomeRegion && t.HomeRegion !== region ? client(profile, t.HomeRegion) : c;
  const parts = await settle(
    {
      status: home.send(new GetTrailStatusCommand({ Name: arn })),
      selectors: home.send(new GetEventSelectorsCommand({ TrailName: arn })),
      insights: home.send(new GetInsightSelectorsCommand({ TrailName: arn })),
      tags: home.send(new ListTagsCommand({ ResourceIdList: [arn] })),
    },
    errors,
    (err) => (err as { name?: string })?.name === 'InsightNotEnabledException',
  );
  const s = parts.status;
  const sel = parts.selectors;
  return {
    id,
    title: t.Name || arn,
    subtitle: t.IsMultiRegionTrail ? 'Multi-region trail' : `Trail in ${t.HomeRegion}`,
    status: s ? (s.IsLogging ? 'LOGGING' : 'STOPPED') : undefined,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Trail', [
            ['Name', t.Name],
            ['Home region', t.HomeRegion],
            ['Multi-region', t.IsMultiRegionTrail],
            ['Organization trail', t.IsOrganizationTrail],
            ['Include global service events', t.IncludeGlobalServiceEvents],
            ['Log file validation', t.LogFileValidationEnabled],
            ['KMS key', t.KmsKeyId],
          ]),
          section('Delivery', [
            ['S3 bucket', t.S3BucketName],
            ['S3 prefix', t.S3KeyPrefix],
            ['SNS topic', t.SnsTopicARN],
            ['CloudWatch Logs group', t.CloudWatchLogsLogGroupArn],
            ['CloudWatch Logs role', t.CloudWatchLogsRoleArn],
          ]),
          section('Status', [
            ['Logging', s?.IsLogging],
            ['Started', s?.StartLoggingTime],
            ['Stopped', s?.StopLoggingTime],
            ['Latest delivery', s?.LatestDeliveryTime],
            ['Latest delivery error', s?.LatestDeliveryError],
            ['Latest digest delivery', s?.LatestDigestDeliveryTime],
            ['Latest CloudWatch Logs delivery', s?.LatestCloudWatchLogsDeliveryTime],
            ['Latest CloudWatch Logs error', s?.LatestCloudWatchLogsDeliveryError],
          ]),
        ],
      }),
      tab('Event selectors', {
        tables: [
          table(
            ['Read/write', 'Management events', 'Data resources', 'Excluded sources'],
            (sel?.EventSelectors || []).map((e) => [e.ReadWriteType, e.IncludeManagementEvents, (e.DataResources || []).map((d) => `${d.Type}: ${(d.Values || []).join(', ')}`), e.ExcludeManagementEventSources]),
            { title: 'Basic event selectors', emptyMessage: 'No basic event selectors' },
          ),
          table(
            ['Name', 'Field selectors'],
            (sel?.AdvancedEventSelectors || []).map((a) => [
              a.Name,
              (a.FieldSelectors || []).map((f) => `${f.Field} ${[f.Equals && `= ${f.Equals.join('|')}`, f.StartsWith && `starts ${f.StartsWith.join('|')}`, f.NotEquals && `≠ ${f.NotEquals.join('|')}`, f.NotStartsWith && `!starts ${f.NotStartsWith.join('|')}`].filter(Boolean).join(' ')}`).join('; '),
            ]),
            { title: 'Advanced event selectors', emptyMessage: 'No advanced event selectors' },
          ),
          table(['Insight type'], (parts.insights?.InsightSelectors || []).map((i) => [i.InsightType]), { title: 'Insights', emptyMessage: 'CloudTrail Insights is off' }),
        ],
      }),
    ],
    tags: tagList(parts.tags?.ResourceTagList?.[0]?.TagsList),
    actions: [],
    errors,
  };
}

async function storePage(c: CloudTrailClient, id: string, arn: string): Promise<ResourcePage> {
  const s = await c.send(new GetEventDataStoreCommand({ EventDataStore: arn }));
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsCommand({ ResourceIdList: [arn] })) }, errors);
  return {
    id,
    title: s.Name || arn,
    subtitle: 'CloudTrail Lake event data store',
    status: s.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Event data store', [
            ['Name', s.Name],
            ['Status', s.Status],
            ['Multi-region', s.MultiRegionEnabled],
            ['Organization', s.OrganizationEnabled],
            ['Retention (days)', s.RetentionPeriod],
            ['Termination protection', s.TerminationProtectionEnabled],
            ['Billing mode', s.BillingMode],
            ['Federation', s.FederationStatus],
            ['KMS key', s.KmsKeyId],
            ['Created', s.CreatedTimestamp],
            ['Updated', s.UpdatedTimestamp],
          ]),
        ],
        tables: [
          table(['Name', 'Field selectors'], (s.AdvancedEventSelectors || []).map((a) => [a.Name, (a.FieldSelectors || []).map((f) => `${f.Field} ${(f.Equals || f.StartsWith || f.NotEquals || []).join('|')}`).join('; ')]), { title: 'Event selectors', emptyMessage: 'No selectors' }),
        ],
      }),
    ],
    tags: tagList(tags?.ResourceTagList?.[0]?.TagsList),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'events') return eventsPage(c, region);
  if (kind === 'trail') return trailPage(profile, region, id, arn);
  if (kind === 'eds') return storePage(c, id, arn);
  throw httpError(`Unknown CloudTrail page: ${id}`, 400);
}

/** Tags go to the trail's home region (the ARN's 4th field). */
const tagClient = (profile: string, region: string, arn: string) => client(profile, arn.split(':')[3] || region);

export const cloudTrailAdapter: PageServiceAdapter = {
  list: (profile, region) => list(profile, region).catch((err) => (isNotEnabled(err) ? [] : Promise.reject(err))),
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    const [kind, arn] = splitId(id);
    if (kind !== 'trail' && kind !== 'eds') throw httpError('Event history has no tags', 400);
    await tagClient(profile, region, arn).send(new AddTagsCommand({ ResourceId: arn, TagsList: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    const [kind, arn] = splitId(id);
    if (kind !== 'trail' && kind !== 'eds') throw httpError('Event history has no tags', 400);
    await tagClient(profile, region, arn).send(new RemoveTagsCommand({ ResourceId: arn, TagsList: [{ Key: key }] }));
  },
  countable: (row) => row.id.startsWith('trail:'),
};
