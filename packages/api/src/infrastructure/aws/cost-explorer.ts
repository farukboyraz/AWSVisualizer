import { CostExplorerClient, GetCostAndUsageCommand } from '@aws-sdk/client-cost-explorer';
import { cachedCredentials } from './credential-cache.js';
import type { CostSummary } from '../../domain/entities/index.js';

function createCostClient(profile: string): CostExplorerClient {
  return new CostExplorerClient({
    region: 'us-east-1', // Cost Explorer only works in us-east-1
    credentials: cachedCredentials(profile),
  });
}

export type CostView = 'daily' | 'monthly' | 'month';

export interface CostQuery {
  view: CostView;
  /** monthly: how many months back (the current month included). */
  months?: number;
  /** month: `YYYY-MM`; defaults to the current month. */
  month?: string;
}

const iso = (d: Date) => d.toISOString().split('T')[0];
const utc = (y: number, m: number, d = 1) => new Date(Date.UTC(y, m, d));

/** [start, end) of the query - Cost Explorer's End is exclusive. */
export function costRange(query: CostQuery, now = new Date()): { start: string; end: string; granularity: 'DAILY' | 'MONTHLY' } {
  const today = utc(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  if (query.view === 'daily') {
    return { start: iso(new Date(today.getTime() - 30 * 86_400_000)), end: iso(today), granularity: 'DAILY' };
  }
  if (query.view === 'monthly') {
    const months = query.months ?? 6;
    return { start: iso(utc(now.getUTCFullYear(), now.getUTCMonth() - (months - 1))), end: iso(today), granularity: 'MONTHLY' };
  }
  const [y, m] = (query.month ?? `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`).split('-').map(Number);
  const first = utc(y, m - 1);
  const next = utc(y, m);
  // Current month: up to today. On the 1st there is no finished day yet - show last month.
  if (next > today) {
    if (first.getTime() === today.getTime()) return { start: iso(utc(y, m - 2)), end: iso(first), granularity: 'DAILY' };
    return { start: iso(first), end: iso(today), granularity: 'DAILY' };
  }
  return { start: iso(first), end: iso(next), granularity: 'DAILY' };
}

/**
 * Spend for the dashboard: total, per service and per day / month, from
 * ONE GetCostAndUsage call (grouped by SERVICE; pages followed). Each Cost
 * Explorer request is billed (~$0.01), so the caller caches the answer.
 */
export async function getCost(profile: string, query: CostQuery): Promise<CostSummary> {
  const client = createCostClient(profile);
  const { start, end, granularity } = costRange(query);

  const byService = new Map<string, number>();
  const byPeriod = new Map<string, number>();
  const periodServices = new Map<string, Map<string, number>>();
  let currency = 'USD';
  let NextPageToken: string | undefined;
  do {
    const response = await client.send(
      new GetCostAndUsageCommand({
        TimePeriod: { Start: start, End: end },
        Granularity: granularity,
        Metrics: ['UnblendedCost'],
        GroupBy: [{ Type: 'DIMENSION', Key: 'SERVICE' }],
        NextPageToken,
      }),
    );
    for (const period of response.ResultsByTime || []) {
      const date = period.TimePeriod?.Start || '';
      byPeriod.set(date, byPeriod.get(date) ?? 0);
      for (const g of period.Groups || []) {
        const amount = parseFloat(g.Metrics?.UnblendedCost?.Amount || '0');
        if (g.Metrics?.UnblendedCost?.Unit) currency = g.Metrics.UnblendedCost.Unit;
        const service = g.Keys?.[0] || 'Unknown';
        byService.set(service, (byService.get(service) ?? 0) + amount);
        byPeriod.set(date, (byPeriod.get(date) ?? 0) + amount);
        const services = periodServices.get(date) ?? new Map<string, number>();
        services.set(service, (services.get(service) ?? 0) + amount);
        periodServices.set(date, services);
      }
    }
    NextPageToken = response.NextPageToken;
  } while (NextPageToken);

  const total = [...byService.values()].reduce((a, b) => a + b, 0);
  return {
    totalCost: total.toFixed(2),
    currency,
    period: { start, end },
    granularity: granularity === 'DAILY' ? 'daily' : 'monthly',
    view: query.view,
    serviceBreakdown: [...byService]
      .map(([service, amount]) => ({ service, amount: amount.toFixed(2) }))
      .filter((x) => parseFloat(x.amount) > 0)
      .sort((a, b) => parseFloat(b.amount) - parseFloat(a.amount)),
    daily: [...byPeriod].sort(([a], [b]) => a.localeCompare(b)).map(([date, amount]) => ({ date, amount: amount.toFixed(2) })),
    // Per day / month: the services that cost something, largest first (chart "Details").
    breakdown: Object.fromEntries(
      [...periodServices].map(([date, services]) => [
        date,
        [...services]
          .filter(([, amount]) => amount >= 0.005)
          .sort(([, a], [, b]) => b - a)
          .map(([service, amount]) => ({ service, amount: amount.toFixed(2) })),
      ]),
    ),
  };
}
