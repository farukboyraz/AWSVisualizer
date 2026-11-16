// CloudWatch graphs (G2): the shared metric endpoint
// (POST /api/cloudwatch/metric-data) and the ResourcePage `charts` use these.

export interface MetricDimension {
  name: string;
  value: string;
}

/** One series: a CloudWatch metric with its dimensions and statistic. */
export interface MetricQuery {
  /** Unique within the request; letters, digits and _ (CloudWatch's rule). */
  id: string;
  namespace: string;
  metricName: string;
  dimensions: MetricDimension[];
  /** Average, Sum, Minimum, Maximum, SampleCount or a percentile (p99). */
  stat: string;
  /** Legend text; defaults to the metric name. */
  label?: string;
}

/** Time ranges the app offers, like the console's 1h / 3h / 12h / 1d / 3d / 1w. */
export const METRIC_RANGES = ['1h', '3h', '12h', '1d', '3d', '1w'] as const;
export type MetricRange = (typeof METRIC_RANGES)[number];

export interface MetricPoint {
  /** ISO timestamp. */
  t: string;
  v: number;
}

export interface MetricSeries {
  id: string;
  label: string;
  points: MetricPoint[];
}

export interface MetricDataResult {
  range: MetricRange;
  /** Seconds per point (chosen from the range). */
  period: number;
  series: MetricSeries[];
  /** CloudWatch messages (partial data, permission problems). */
  messages: string[];
}
