import type { ResourcePage, PageSummary, PageAction } from '../../domain/entities/index.js';
import type { OptionSource } from '../dashboard-cards/types.js';

/**
 * One ResourcePage service as the shared routes see it. `id` values
 * are opaque to the app (adapters encode a kind prefix where a service
 * lists several resource types, e.g. `rg:` / `cc:` in ElastiCache).
 */
export interface PageServiceAdapter {
  list(profile: string, region: string): Promise<PageSummary[]>;
  detail(profile: string, region: string, id: string): Promise<ResourcePage>;
  /**
   * Runs one of the page's `actions`; unknown ids must throw a 400. The
   * route only calls it for an action the page currently offers, with
   * `params` already checked against that action's `form`.
   */
  action?(profile: string, region: string, id: string, action: string, params: Record<string, string>): Promise<void>;
  /**
   * List-level "New ..." forms (the app shows a + button per form). Static:
   * the same for every profile / region.
   */
  createForms?: PageAction[];
  /** Runs a create form (params already checked); returns the new row's id to select it. */
  create?(profile: string, region: string, form: string, params: Record<string, string>): Promise<string | void>;
  /** Dropdown sources for `combo` fields (read-only AWS calls). */
  options?: Record<string, OptionSource>;
  addTag?(profile: string, region: string, id: string, arn: string, key: string, value: string): Promise<void>;
  removeTag?(profile: string, region: string, id: string, arn: string, key: string): Promise<void>;
  /** Dashboard count filter; defaults to every list row. */
  countable?(row: PageSummary): boolean;
  /** No dashboard count (account-level services whose rows aren't resources). */
  uncounted?: boolean;
}

/** Splits `kind:rest` ids. */
export function splitId(id: string): [string, string] {
  const i = id.indexOf(':');
  return i < 0 ? ['', id] : [id.slice(0, i), id.slice(i + 1)];
}

/**
 * For services that list a single resource type, so their ids would
 * otherwise be the bare name / ARN: rows get a `kind:` prefix like every
 * other service, and an id without it is rejected with a 400 before any
 * AWS call. The wrapped adapter keeps working with the bare value.
 */
export function singleKind(kind: string, inner: PageServiceAdapter): PageServiceAdapter {
  const strip = (id: string): string => {
    const [k, rest] = splitId(id);
    if (k !== kind || !rest) throw Object.assign(new Error(`Unknown id: ${id} (expected ${kind}:…)`), { $metadata: { httpStatusCode: 400 } });
    return rest;
  };
  return {
    ...inner,
    async list(profile, region) {
      return (await inner.list(profile, region)).map((row) => ({ ...row, id: `${kind}:${row.id}` }));
    },
    async detail(profile, region, id) {
      const page = await inner.detail(profile, region, strip(id));
      return { ...page, id: `${kind}:${page.id}` };
    },
    action: inner.action && ((profile, region, id, action, params) => inner.action!(profile, region, strip(id), action, params)),
    create:
      inner.create &&
      (async (profile, region, form, params) => {
        const id = await inner.create!(profile, region, form, params);
        return id ? `${kind}:${id}` : undefined;
      }),
    addTag: inner.addTag && ((profile, region, id, arn, key, value) => inner.addTag!(profile, region, strip(id), arn, key, value)),
    removeTag: inner.removeTag && ((profile, region, id, arn, key) => inner.removeTag!(profile, region, strip(id), arn, key)),
  };
}
