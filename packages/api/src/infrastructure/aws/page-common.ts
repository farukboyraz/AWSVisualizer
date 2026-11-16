import type { PageChart, PageFormField, PageSection, PageTab, PageTable, StorageSetting, StorageTag } from '../../domain/entities/index.js';
import { getCallerIdentity } from './sts.js';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';

/** Drops empty values; booleans become Enabled/Disabled, dates ISO strings, arrays comma lists. */
export function settings(pairs: [string, unknown][]): StorageSetting[] {
  return pairs
    .filter(([, v]) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0))
    .map(([label, v]) => ({ label, value: fmt(v) }));
}

export function fmt(v: unknown): string {
  if (v === undefined || v === null || v === '') return '-';
  if (typeof v === 'boolean') return v ? 'Enabled' : 'Disabled';
  if (v instanceof Date) return v.toISOString();
  if (Array.isArray(v)) return v.map(fmt).join(', ');
  return String(v);
}

export function section(title: string, pairs: [string, unknown][], extra: Partial<PageSection> = {}): PageSection {
  return { title, settings: settings(pairs), ...extra };
}

export function table(columns: string[], rows: unknown[][], opts: Partial<PageTable> = {}): PageTable {
  return { columns, rows: rows.map((r) => r.map(fmt)), ...opts };
}

export function tab(title: string, parts: Partial<PageTab> = {}): PageTab {
  return { title, sections: [], tables: [], ...parts };
}

export const errorText = (label: string, err: unknown) => `${label}: ${err instanceof Error ? err.message : String(err)}`;

/** Runs named parts in parallel; failed parts land in `errors` and resolve to `fallback`. */
export async function settle<T extends Record<string, Promise<unknown>>>(
  parts: T,
  errors: string[],
  ignore: (err: unknown) => boolean = () => false,
): Promise<{ [K in keyof T]: Awaited<T[K]> | undefined }> {
  const keys = Object.keys(parts);
  const results = await Promise.allSettled(Object.values(parts));
  const out: Record<string, unknown> = {};
  results.forEach((r, i) => {
    if (r.status === 'fulfilled') out[keys[i]] = r.value;
    else {
      if (!ignore(r.reason)) errors.push(errorText(keys[i], r.reason));
      out[keys[i]] = undefined;
    }
  });
  return out as { [K in keyof T]: Awaited<T[K]> | undefined };
}

export const tagList = (tags?: { Key?: string; Value?: string }[]): StorageTag[] =>
  (tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' }));

export const endpointText = (e?: { Address?: string; Port?: number }) => (e?.Address ? `${e.Address}:${e.Port ?? ''}` : undefined);

export const httpError = (message: string, status: number) => Object.assign(new Error(message), { $metadata: { httpStatusCode: status } });

/** Events from the last 7 days, in minutes (most event APIs take a Duration). */
export const EVENT_WINDOW_MINUTES = 7 * 24 * 60;
export const EVENT_WINDOW_START = () => new Date(Date.now() - EVENT_WINDOW_MINUTES * 60_000);

export const lastPart = (arn?: string) => arn?.split(/[:/]/).pop();

/** `Promise.all` with at most `limit` calls in flight (for per-item Describe calls). */
export async function mapLimited<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

/**
 * Pages any token-paginated call: `call(token)` returns the response,
 * `pick` the items and `next` the following token.
 */
export async function pageAll<R, T>(
  call: (token?: string) => Promise<R>,
  pick: (r: R) => T[] | undefined,
  next: (r: R) => string | undefined,
  limit = 5000,
): Promise<T[]> {
  const out: T[] = [];
  let token: string | undefined;
  do {
    const res = await call(token);
    out.push(...(pick(res) || []));
    token = next(res);
  } while (token && out.length < limit);
  return out;
}

const accountIds = new Map<string, Promise<string>>();

/** The profile's account id (cached per profile), for building ARNs the APIs don't return. */
export function accountId(profile: string, region: string): Promise<string> {
  let p = accountIds.get(profile);
  if (!p) {
    p = getCallerIdentity(profile, region).then((r) => r.account);
    p.catch(() => accountIds.delete(profile));
    accountIds.set(profile, p);
  }
  return p;
}

/** Pretty-prints a JSON policy document (IAM returns them URL-encoded). */
export function policyJson(doc?: string): string | undefined {
  if (!doc) return undefined;
  let text = doc;
  try {
    text = decodeURIComponent(doc);
  } catch {
    // Already decoded.
  }
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

/** `{ key: value }` tag maps (most newer APIs) → the page's tag list. */
export const tagMap = (tags?: Record<string, string>) => Object.entries(tags || {}).map(([key, value]) => ({ key, value }));

/** AccessDenied-style "service isn't turned on here" errors, which mean an empty list rather than a failure. */
export function isNotEnabled(err: unknown): boolean {
  const e = err as { name?: string; message?: string };
  return /not ?enabled|not subscribed|not been enabled|isn't enabled|is not an? (administrator|admin)|ResourceNotFound/i.test(`${e?.name} ${e?.message}`);
}

/** `{ region, credentials }` for any SDK client of a profile. */
export const clientConfig = (profile: string, region: string) => ({ region, credentials: cachedCredentials(profile) });

/** List rows sorted by name. */
export const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);

/** A ResourcePage without actions or errors (simple read-only pages). */
export const basicPage = (id: string, title: string, subtitle: string, tabs: PageTab[], extra: Partial<ResourcePage> = {}): ResourcePage => ({ id, title, subtitle, tabs, actions: [], errors: [], ...extra });

/**
 * A CloudWatch graph for a page's Monitoring tab: one series per metric,
 * all with the same dimensions (`[name, stat, label?]`).
 */
export function metricChart(title: string, namespace: string, dimensions: Record<string, string>, metrics: [string, string, string?][], unit?: string): PageChart {
  const dims = Object.entries(dimensions).map(([name, value]) => ({ name, value }));
  return {
    title,
    unit,
    queries: metrics.map(([metricName, stat, label], i) => ({ id: `m${i}`, namespace, metricName, dimensions: dims, stat, label: label ?? metricName })),
  };
}

/** `2026-11-16-1430` - default suffix for manual snapshot names. */
export const nameStamp = (d = new Date()) => d.toISOString().slice(0, 16).replace('T', '-').replace(':', '');

/**
 * Snapshot name field for RDS-family and Redshift snapshots: 1-255 letters,
 * digits and hyphens, starts with a letter, no "--", doesn't end with "-".
 */
export function snapshotNameField(defaultValue: string): PageFormField {
  return {
    key: 'name',
    label: { en: 'Snapshot name', tr: 'Snapshot adı' },
    type: 'text',
    required: true,
    maxLength: 255,
    pattern: '^[A-Za-z](?!.*--)[A-Za-z0-9-]*[A-Za-z0-9]$|^[A-Za-z]$',
    patternMessage: {
      en: 'letters, digits and hyphens; starts with a letter; no "--"; doesn\'t end with "-"',
      tr: 'harf, rakam ve tire; harfle başlar; "--" içermez; "-" ile bitmez',
    },
    defaultValue: defaultValue.replace(/[^A-Za-z0-9-]/g, '-').replace(/-+/g, '-').replace(/^[^A-Za-z]+/, '').slice(0, 255).replace(/-$/, ''),
  };
}
