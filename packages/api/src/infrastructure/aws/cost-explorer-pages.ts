import { CostExplorerClient, GetCostAndUsageCommand, GetCostForecastCommand, type ResultByTime } from '@aws-sdk/client-cost-explorer';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Cost Explorer only answers in us-east-1. */
const client = (p: string) => new CostExplorerClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

/** Every Cost Explorer API request is billed (~$0.01), so the list makes none and each page makes one or two. */
const COST_NOTE = 'Each page load makes 1-2 Cost Explorer API requests, which AWS bills at $0.01 each. Data lags up to 24 hours.';

const day = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (d: Date, n: number) => new Date(d.getTime() + n * 86_400_000);
const monthStart = (d: Date, offset = 0) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offset, 1));

const amount = (m?: { Amount?: string; Unit?: string }) => (m?.Amount ? Number(m.Amount) : 0);
const usd = (n: number, unit = 'USD') => (unit === 'USD' ? `$${n.toFixed(2)}` : `${n.toFixed(2)} ${unit}`);

const PAGES: Record<string, { name: string; info: string }> = {
  svc: { name: 'By service', info: 'This month and last month, per service' },
  daily: { name: 'Daily spend', info: 'Last 30 days' },
  region: { name: 'By region', info: 'This month, per region' },
  acct: { name: 'By linked account', info: 'This month, per account' },
  fc: { name: 'Forecast', info: 'Projected total for this month' },
};

async function list(): Promise<PageSummary[]> {
  return Object.entries(PAGES).map(([k, p]) => ({ id: `${k}:`, name: p.name, group: 'Cost & usage', info: p.info }));
}

/** Month-to-date window; on the 1st (empty window) it falls back to last month. */
function thisMonth(now = new Date()) {
  const start = monthStart(now);
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  return day(start) === day(end) ? { Start: day(monthStart(now, -1)), End: day(start), label: 'Last month' } : { Start: day(start), End: day(end), label: 'Month to date' };
}

async function grouped(c: CostExplorerClient, Key: string, period: { Start: string; End: string }) {
  const r = await c.send(new GetCostAndUsageCommand({ TimePeriod: period, Granularity: 'MONTHLY', Metrics: ['UnblendedCost'], GroupBy: [{ Type: 'DIMENSION', Key }] }));
  return r.ResultsByTime || [];
}

/** Sums each group key across periods. */
function totals(results: ResultByTime[]) {
  const m = new Map<string, number>();
  let unit = 'USD';
  for (const r of results)
    for (const g of r.Groups || []) {
      const cost = g.Metrics?.UnblendedCost;
      unit = cost?.Unit || unit;
      m.set(g.Keys?.[0] || 'Other', (m.get(g.Keys?.[0] || 'Other') ?? 0) + amount(cost));
    }
  return { rows: [...m.entries()].filter(([, v]) => Math.abs(v) >= 0.005).sort((a, b) => b[1] - a[1]), unit };
}

function page(id: string, subtitle: string, tabs: ResourcePage['tabs']): ResourcePage {
  const [kind] = splitId(id);
  return { id, title: PAGES[kind].name, subtitle, tabs, actions: [], errors: [] };
}

async function byDimension(c: CostExplorerClient, id: string, key: string, label: string): Promise<ResourcePage> {
  const period = thisMonth();
  const { rows, unit } = totals(await grouped(c, key, period));
  const total = rows.reduce((n, [, v]) => n + v, 0);
  return page(id, `${period.label}: ${usd(total, unit)}`, [
    tab('Costs', {
      sections: [section('Period', [['From', period.Start], ['To (exclusive)', period.End], ['Total (unblended)', usd(total, unit)]], { note: COST_NOTE })],
      tables: [table([label, 'Cost', 'Share'], rows.map(([k, v]) => [k, usd(v, unit), total ? `${((v / total) * 100).toFixed(1)}%` : '-']), { emptyMessage: 'No costs in this period' })],
    }),
  ]);
}

async function byService(c: CostExplorerClient, id: string): Promise<ResourcePage> {
  const now = new Date();
  const cur = thisMonth(now);
  const lastStart = day(monthStart(now, -1));
  // One request covering last month + this month (two MONTHLY periods).
  const results = await grouped(c, 'SERVICE', { Start: cur.label === 'Last month' ? day(monthStart(now, -2)) : lastStart, End: cur.End });
  const [prev, curr] = results.length >= 2 ? [results[0], results[results.length - 1]] : [undefined, results[0]];
  const current = totals(curr ? [curr] : []);
  const previous = new Map(totals(prev ? [prev] : []).rows);
  const total = current.rows.reduce((n, [, v]) => n + v, 0);
  const prevTotal = [...previous.values()].reduce((n, v) => n + v, 0);
  return page(id, `${cur.label}: ${usd(total, current.unit)}`, [
    tab('Costs', {
      sections: [section('Totals', [[cur.label, usd(total, current.unit)], ['Previous month', usd(prevTotal, current.unit)]], { note: COST_NOTE })],
      tables: [
        table(
          ['Service', cur.label, 'Previous month', 'Share'],
          current.rows.map(([k, v]) => [k, usd(v, current.unit), previous.has(k) ? usd(previous.get(k)!, current.unit) : '-', total ? `${((v / total) * 100).toFixed(1)}%` : '-']),
          { emptyMessage: 'No costs in this period' },
        ),
      ],
    }),
  ]);
}

async function daily(c: CostExplorerClient, id: string): Promise<ResourcePage> {
  const today = new Date();
  const end = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()));
  const r = await c.send(new GetCostAndUsageCommand({ TimePeriod: { Start: day(addDays(end, -30)), End: day(end) }, Granularity: 'DAILY', Metrics: ['UnblendedCost'] }));
  const days = (r.ResultsByTime || []).map((x) => ({ date: x.TimePeriod?.Start, cost: amount(x.Total?.UnblendedCost), unit: x.Total?.UnblendedCost?.Unit || 'USD', estimated: x.Estimated }));
  const total = days.reduce((n, d) => n + d.cost, 0);
  const unit = days[0]?.unit || 'USD';
  return page(id, `Last 30 days: ${usd(total, unit)}`, [
    tab('Costs', {
      sections: [section('Last 30 days', [['Total', usd(total, unit)], ['Daily average', usd(days.length ? total / days.length : 0, unit)], ['Highest day', days.length ? usd(Math.max(...days.map((d) => d.cost)), unit) : '-']], { note: COST_NOTE })],
      tables: [table(['Date', 'Cost', 'Estimated'], days.reverse().map((d) => [d.date, usd(d.cost, d.unit), d.estimated ? 'Yes' : 'No']), { emptyMessage: 'No data' })],
    }),
  ]);
}

async function forecast(c: CostExplorerClient, id: string): Promise<ResourcePage> {
  const now = new Date();
  const tomorrow = addDays(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())), 1);
  const nextMonth = monthStart(now, 1);
  const mtd = thisMonth(now);
  const actual = mtd.label === 'Month to date' ? totals(await grouped(c, 'RECORD_TYPE', mtd)) : { rows: [] as [string, number][], unit: 'USD' };
  const spent = actual.rows.reduce((n, [, v]) => n + v, 0);
  if (day(tomorrow) >= day(nextMonth)) {
    return page(id, 'Last day of the month', [tab('Forecast', { sections: [section('This month', [['Spent so far', usd(spent, actual.unit)]], { note: `Nothing left to forecast this month. ${COST_NOTE}` })] })]);
  }
  const f = await c.send(new GetCostForecastCommand({ TimePeriod: { Start: day(tomorrow), End: day(nextMonth) }, Metric: 'UNBLENDED_COST', Granularity: 'MONTHLY', PredictionIntervalLevel: 80 }));
  const rest = amount(f.Total);
  const unit = f.Total?.Unit || actual.unit;
  const band = f.ForecastResultsByTime?.[0];
  return page(id, `Projected: ${usd(spent + rest, unit)}`, [
    tab('Forecast', {
      sections: [
        section(
          'This month',
          [
            ['Spent so far', usd(spent, unit)],
            ['Forecast for the rest of the month', usd(rest, unit)],
            ['Projected month total', usd(spent + rest, unit)],
            ['80% range (rest of month)', band ? `${usd(Number(band.PredictionIntervalLowerBound || 0), unit)} – ${usd(Number(band.PredictionIntervalUpperBound || 0), unit)}` : undefined],
          ],
          { note: COST_NOTE },
        ),
      ],
      tables: [table(['Record type', 'Spent so far'], actual.rows.map(([k, v]) => [k, usd(v, actual.unit)]), { title: 'Month to date by record type', emptyMessage: 'No costs yet' })],
    }),
  ]);
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const c = client(profile);
  const [kind] = splitId(id);
  if (kind === 'svc') return byService(c, id);
  if (kind === 'daily') return daily(c, id);
  if (kind === 'region') return byDimension(c, id, 'REGION', 'Region');
  if (kind === 'acct') return byDimension(c, id, 'LINKED_ACCOUNT', 'Account');
  if (kind === 'fc') return forecast(c, id);
  throw httpError(`Unknown Cost Explorer page: ${id}`, 400);
}

export const costExplorerAdapter: PageServiceAdapter = {
  list: () => list(),
  detail,
  uncounted: true,
};
