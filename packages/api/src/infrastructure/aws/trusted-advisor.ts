import {
  TrustedAdvisorClient,
  ListRecommendationsCommand,
  GetRecommendationCommand,
  ListRecommendationResourcesCommand,
  type RecommendationSummary,
} from '@aws-sdk/client-trustedadvisor';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** The Trusted Advisor API is global, served from us-east-1. */
const client = (p: string) => new TrustedAdvisorClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

const RESOURCE_LIMIT = 500;
const PILLAR: Record<string, string> = {
  cost_optimizing: 'Cost optimization',
  performance: 'Performance',
  security: 'Security',
  service_limits: 'Service limits',
  fault_tolerance: 'Fault tolerance',
  operational_excellence: 'Operational excellence',
};
const SEVERITY: Record<string, number> = { error: 0, warning: 1, ok: 2 };

const errName = (err: unknown) => (err as { name?: string })?.name;
/** No Business / Enterprise support (or no permission): nothing to list. */
const unavailable = (err: unknown) => ['AccessDeniedException', 'SubscriptionRequiredException'].includes(errName(err) || '');

const savings = (r: Pick<RecommendationSummary, 'pillarSpecificAggregates'>) => {
  const s = r.pillarSpecificAggregates?.costOptimizing?.estimatedMonthlySavings;
  return s ? `$${s.toFixed(2)}/month` : undefined;
};

/** Descriptions come as HTML snippets. */
const plain = (html?: string) =>
  html
    ?.replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|li|h\d)>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

const bySeverity = (a: { status?: string }, b: { status?: string }) => (SEVERITY[a.status || ''] ?? 3) - (SEVERITY[b.status || ''] ?? 3);

async function list(profile: string): Promise<PageSummary[]> {
  const c = client(profile);
  let recs: RecommendationSummary[];
  try {
    recs = await pageAll((nextToken) => c.send(new ListRecommendationsCommand({ nextToken })), (r) => r.recommendationSummaries, (r) => r.nextToken);
  } catch (err) {
    if (unavailable(err)) return [];
    throw err;
  }
  return recs
    .sort((a, b) => bySeverity(a, b) || (a.name || '').localeCompare(b.name || ''))
    .map((r) => {
      const agg = r.resourcesAggregates;
      return {
        id: `rec:${r.arn}`,
        name: r.name || '',
        group: PILLAR[r.pillars?.[0] || ''] ?? 'Other',
        status: r.status,
        info: [agg && `${agg.errorCount ?? 0} action · ${agg.warningCount ?? 0} investigate · ${agg.okCount ?? 0} ok`, savings(r), r.source].filter(Boolean).join(' · '),
      };
    });
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const [kind, arn] = splitId(id);
  if (kind !== 'rec') throw httpError(`Unknown Trusted Advisor page: ${id}`, 400);
  const c = client(profile);
  const r = (await c.send(new GetRecommendationCommand({ recommendationIdentifier: arn }))).recommendation;
  if (!r) throw httpError(`Recommendation not found: ${arn}`, 404);
  const errors: string[] = [];
  const { resources } = await settle(
    { resources: pageAll((nextToken) => c.send(new ListRecommendationResourcesCommand({ recommendationIdentifier: arn, nextToken })), (x) => x.recommendationResourceSummaries, (x) => x.nextToken, RESOURCE_LIMIT) },
    errors,
  );
  const rows = (resources || []).sort(bySeverity);
  // Metadata keys differ per check; the first few become columns.
  const metaKeys = [...new Set(rows.flatMap((x) => Object.keys(x.metadata || {})))].slice(0, 6);
  const agg = r.resourcesAggregates;
  return {
    id,
    title: r.name || arn,
    subtitle: (r.pillars || []).map((p) => PILLAR[p] ?? p).join(', '),
    status: r.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Recommendation', [
            ['Status', r.status],
            ['Pillars', (r.pillars || []).map((p) => PILLAR[p] ?? p)],
            ['Source', r.source],
            ['Type', r.type],
            ['Lifecycle', r.lifecycleStage],
            ['AWS services', r.awsServices],
            ['Action recommended', agg?.errorCount],
            ['Investigation recommended', agg?.warningCount],
            ['OK', agg?.okCount],
            ['Estimated savings', savings(r)],
            ['Created', r.createdAt],
            ['Updated', r.lastUpdatedAt],
            ['Resolved', r.resolvedAt],
          ]),
        ],
      }),
      tab('Resources', {
        tables: [
          table(
            ['Resource', 'Region', 'Status', ...metaKeys],
            rows.map((x) => [x.awsResourceId, x.regionCode, x.status, ...metaKeys.map((k) => x.metadata?.[k])]),
            { statusColumn: 2, title: rows.length >= RESOURCE_LIMIT ? `First ${RESOURCE_LIMIT} resources` : undefined, emptyMessage: 'No affected resources' },
          ),
        ],
      }),
      tab('Description', { text: plain(r.description) || 'No description' }),
    ],
    actions: [],
    errors,
  };
}

export const trustedAdvisorAdapter: PageServiceAdapter = {
  list: (profile) => list(profile),
  detail,
  uncounted: true,
};
