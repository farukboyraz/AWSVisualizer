import { HealthClient, DescribeEventsCommand, DescribeEventDetailsCommand, DescribeAffectedEntitiesCommand, type Event } from '@aws-sdk/client-health';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** The Health API's global endpoint is in us-east-1. */
const client = (p: string) => new HealthClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

const EVENT_LIMIT = 300;
const ENTITY_LIMIT = 500;
const GROUP: Record<string, string> = { open: 'Open issues', upcoming: 'Scheduled changes', closed: 'Resolved (last 90 days)' };
const ORDER: Record<string, number> = { open: 0, upcoming: 1, closed: 2 };

const errName = (err: unknown) => (err as { name?: string })?.name;
/** The Health API needs a Business, Enterprise On-Ramp or Enterprise support plan. */
const noSupportPlan = (err: unknown) => errName(err) === 'SubscriptionRequiredException';

const label = (e: Event) => (e.eventTypeCode || '').replace(/^AWS_/, '').replace(/_/g, ' ').toLowerCase().replace(/^\w/, (x) => x.toUpperCase());

async function list(profile: string): Promise<PageSummary[]> {
  const c = client(profile);
  let events: Event[];
  try {
    events = await pageAll((nextToken) => c.send(new DescribeEventsCommand({ nextToken, maxResults: 100 })), (r) => r.events, (r) => r.nextToken, EVENT_LIMIT);
  } catch (err) {
    if (noSupportPlan(err)) return [];
    throw err;
  }
  return events
    .sort((a, b) => (ORDER[a.statusCode || ''] ?? 3) - (ORDER[b.statusCode || ''] ?? 3) || (b.lastUpdatedTime?.getTime() ?? 0) - (a.lastUpdatedTime?.getTime() ?? 0))
    .map((e) => ({
      id: `ev:${e.arn}`,
      name: `${e.service ?? ''}: ${label(e)}`,
      group: GROUP[e.statusCode || ''] ?? 'Other',
      status: e.statusCode,
      info: [e.region, e.eventTypeCategory, e.startTime && `since ${e.startTime.toISOString().slice(0, 16).replace('T', ' ')}`].filter(Boolean).join(' · '),
    }));
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const [kind, arn] = splitId(id);
  if (kind !== 'ev') throw httpError(`Unknown Health page: ${id}`, 400);
  const c = client(profile);
  const d = (await c.send(new DescribeEventDetailsCommand({ eventArns: [arn] }))).successfulSet?.[0];
  const e = d?.event;
  if (!e) throw httpError(`Health event not found: ${arn}`, 404);
  const errors: string[] = [];
  const { entities } = await settle(
    { entities: pageAll((nextToken) => c.send(new DescribeAffectedEntitiesCommand({ filter: { eventArns: [arn] }, nextToken })), (r) => r.entities, (r) => r.nextToken, ENTITY_LIMIT) },
    errors,
  );
  const meta = Object.entries(d?.eventMetadata || {});
  return {
    id,
    title: `${e.service ?? ''}: ${label(e)}`,
    subtitle: [e.region, e.availabilityZone, e.eventTypeCategory].filter(Boolean).join(' · '),
    status: e.statusCode,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Event', [
            ['Service', e.service],
            ['Event type', e.eventTypeCode],
            ['Category', e.eventTypeCategory],
            ['Status', e.statusCode],
            ['Region', e.region],
            ['Availability Zone', e.availabilityZone],
            ['Scope', e.eventScopeCode],
            ['Start', e.startTime],
            ['End', e.endTime],
            ['Last updated', e.lastUpdatedTime],
          ]),
        ],
        tables: meta.length ? [table(['Key', 'Value'], meta, { title: 'Metadata' })] : [],
      }),
      tab('Description', { text: d?.eventDescription?.latestDescription || 'No description' }),
      tab('Affected resources', {
        tables: [table(['Resource', 'Account', 'Status', 'Updated'], (entities || []).map((x) => [x.entityValue, x.awsAccountId, x.statusCode, x.lastUpdatedTime]), { statusColumn: 2, emptyMessage: 'No specific resources listed' })],
      }),
    ],
    actions: [],
    errors,
  };
}

export const healthAdapter: PageServiceAdapter = {
  list: (profile) => list(profile),
  detail,
  uncounted: true,
};
