import { CloudWatchClient, GetMetricDataCommand, type MetricDataQuery } from '@aws-sdk/client-cloudwatch';
import { cachedCredentials } from './credential-cache.js';
import { httpError } from './page-common.js';
import { METRIC_RANGES, type MetricDataResult, type MetricQuery, type MetricRange, type MetricSeries } from '../../domain/entities/index.js';

/**
 * CloudWatch graphs (G2): one `GetMetricData` call for every series of a
 * chart grid. Used by the shared MetricChart in the app - the ResourcePage
 * `charts` and the Monitor tabs of Lambda, RDS and DynamoDB.
 */

/** Look-back and seconds per point, like the console's defaults for each range. */
const RANGES: Record<MetricRange, { hours: number; period: number }> = {
  '1h': { hours: 1, period: 60 },
  '3h': { hours: 3, period: 60 },
  '12h': { hours: 12, period: 300 },
  '1d': { hours: 24, period: 300 },
  '3d': { hours: 72, period: 900 },
  '1w': { hours: 168, period: 3600 },
};

const MAX_QUERIES = 20;
/** CloudWatch's id rule: starts with a lowercase letter; letters, digits and _. */
const ID = /^[a-z][a-zA-Z0-9_]{0,254}$/;
const STAT = /^(Average|Sum|Minimum|Maximum|SampleCount|p(100|\d{1,2}(\.\d{1,2})?))$/;

const bad = (message: string) => httpError(message, 400);

/** Checks the request before any AWS call (400 with the reason). */
export function checkMetricRequest(range: unknown, queries: unknown): { range: MetricRange; queries: MetricQuery[] } {
  if (typeof range !== 'string' || !(METRIC_RANGES as readonly string[]).includes(range)) throw bad(`range must be one of ${METRIC_RANGES.join(', ')}`);
  if (!Array.isArray(queries) || queries.length === 0) throw bad('queries must be a non-empty list');
  if (queries.length > MAX_QUERIES) throw bad(`At most ${MAX_QUERIES} series per request`);
  const ids = new Set<string>();
  const checked = queries.map((raw, i): MetricQuery => {
    const q = (raw ?? {}) as Record<string, unknown>;
    const id = q.id, namespace = q.namespace, metricName = q.metricName, stat = q.stat;
    if (typeof id !== 'string' || !ID.test(id)) throw bad(`queries[${i}].id must start with a lowercase letter and contain only letters, digits and _`);
    if (ids.has(id)) throw bad(`queries[${i}].id is repeated: ${id}`);
    ids.add(id);
    if (typeof namespace !== 'string' || !namespace || namespace.length > 255) throw bad(`queries[${i}].namespace is required (at most 255 characters)`);
    if (typeof metricName !== 'string' || !metricName || metricName.length > 255) throw bad(`queries[${i}].metricName is required (at most 255 characters)`);
    if (typeof stat !== 'string' || !STAT.test(stat)) throw bad(`queries[${i}].stat must be Average, Sum, Minimum, Maximum, SampleCount or a percentile like p99`);
    const dims = Array.isArray(q.dimensions) ? q.dimensions : [];
    if (dims.length > 30) throw bad(`queries[${i}] has more than 30 dimensions`);
    const dimensions = dims.map((d, j) => {
      const dim = (d ?? {}) as Record<string, unknown>;
      if (typeof dim.name !== 'string' || !dim.name || typeof dim.value !== 'string' || !dim.value || dim.name.length > 255 || dim.value.length > 1024) {
        throw bad(`queries[${i}].dimensions[${j}] needs a name and a value`);
      }
      return { name: dim.name, value: dim.value };
    });
    const label = typeof q.label === 'string' && q.label ? q.label.slice(0, 255) : undefined;
    return { id, namespace, metricName, dimensions, stat, label };
  });
  return { range: range as MetricRange, queries: checked };
}

export async function getMetricData(profile: string, region: string, range: MetricRange, queries: MetricQuery[], now = new Date()): Promise<MetricDataResult> {
  const { hours, period } = RANGES[range];
  const end = new Date(Math.floor(now.getTime() / (period * 1000)) * period * 1000);
  const start = new Date(end.getTime() - hours * 3_600_000);
  const client = new CloudWatchClient({ region, credentials: cachedCredentials(profile) });
  const dataQueries: MetricDataQuery[] = queries.map((q) => ({
    Id: q.id,
    Label: q.label ?? q.metricName,
    ReturnData: true,
    MetricStat: {
      Metric: { Namespace: q.namespace, MetricName: q.metricName, Dimensions: q.dimensions.map((d) => ({ Name: d.name, Value: d.value })) },
      Period: period,
      Stat: q.stat,
    },
  }));

  const byId = new Map<string, MetricSeries>(queries.map((q) => [q.id, { id: q.id, label: q.label ?? q.metricName, points: [] }]));
  const messages = new Set<string>();
  let NextToken: string | undefined;
  do {
    const res = await client.send(new GetMetricDataCommand({ MetricDataQueries: dataQueries, StartTime: start, EndTime: end, ScanBy: 'TimestampAscending', NextToken }));
    for (const r of res.MetricDataResults || []) {
      const series = r.Id ? byId.get(r.Id) : undefined;
      if (!series) continue;
      const ts = r.Timestamps || [];
      const vs = r.Values || [];
      for (let i = 0; i < Math.min(ts.length, vs.length); i++) series.points.push({ t: ts[i].toISOString(), v: vs[i] });
      for (const m of r.Messages || []) if (m.Value) messages.add(`${series.label}: ${m.Value}`);
      if (r.StatusCode === 'PartialData') messages.add(`${series.label}: partial data`);
    }
    for (const m of res.Messages || []) if (m.Value) messages.add(m.Value);
    NextToken = res.NextToken;
  } while (NextToken);

  const series = [...byId.values()].map((s) => ({ ...s, points: s.points.sort((a, b) => a.t.localeCompare(b.t)) }));
  return { range, period, series, messages: [...messages] };
}
