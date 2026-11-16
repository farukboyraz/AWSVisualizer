import { SERVICE_LISTERS } from '../aws/service-counts.js';
import { PAGE_SERVICES } from '../aws/page-services.js';
import { t, type CardTemplate, type CardContext, type OptionSource } from './types.js';

/**
 * Cards every service gets, built on what the app already has:
 * - Resource count (metric) - the service's list, optionally filtered by
 *   name and status - for every service with a list (the dashboard counts).
 * - Open service (link) - every service.
 * - Open resource (link) - services on the shared ResourcePage screen.
 */

interface Row {
  id: string;
  name: string;
  status: string;
}

const NAME_KEYS = ['name', 'Name', 'title', 'functionName', 'FunctionName', 'tableName', 'bucketName', 'queueName', 'alarmName', 'repositoryName', 'clusterName', 'environmentName', 'stackName', 'distributionId', 'instanceId', 'keyId', 'id'];
const STATUS_KEYS = ['status', 'Status', 'state', 'State', 'environmentStatus', 'stackStatus', 'health'];

/** Listers return different shapes per service; pick a name and a status. */
function normalize(item: unknown): Row {
  if (typeof item === 'string') return { id: item, name: item, status: '' };
  const o = (item ?? {}) as Record<string, unknown>;
  const pick = (keys: string[]) => {
    for (const k of keys) {
      const v = o[k];
      if (typeof v === 'string' && v) return v;
      if (v && typeof v === 'object' && typeof (v as any).Name === 'string') return (v as any).Name as string;
    }
    return '';
  };
  const name = pick(NAME_KEYS);
  return { id: typeof o.id === 'string' ? o.id : name, name, status: pick(STATUS_KEYS) };
}

async function rows(service: string, ctx: { profile: string; region: string }): Promise<Row[]> {
  const lister = SERVICE_LISTERS[service];
  if (!lister) return [];
  return (await lister(ctx.profile, ctx.region)).map(normalize);
}

function filtered(list: Row[], ctx: CardContext): Row[] {
  const needle = (ctx.params.nameContains || '').trim().toLowerCase();
  const status = (ctx.params.status || '').trim().toLowerCase();
  return list.filter((r) => (!needle || r.name.toLowerCase().includes(needle)) && (!status || r.status.toLowerCase() === status));
}

/** Option sources shared by every service; `service` comes with the request. */
export const genericOptions: Record<string, (service: string) => OptionSource> = {
  'generic.statuses': (service) => async (ctx) => {
    const counts = new Map<string, number>();
    for (const r of await rows(service, ctx)) if (r.status) counts.set(r.status, (counts.get(r.status) ?? 0) + 1);
    return [...counts].sort((a, b) => b[1] - a[1]).map(([s, n]) => ({ value: s, label: s, detail: `${n}` }));
  },
  'generic.resources': (service) => async (ctx) => {
    const adapter = PAGE_SERVICES[service];
    if (!adapter) return [];
    return (await adapter.list(ctx.profile, ctx.region)).map((r) => ({ value: r.id, label: r.name, detail: [r.group, r.status].filter(Boolean).join(' · ') }));
  },
};

export function genericTemplates(service: string): CardTemplate[] {
  const templates: CardTemplate[] = [];
  if (SERVICE_LISTERS[service]) {
    templates.push({
      id: 'generic.resourceCount',
      kind: 'metric',
      name: t('Resource count', 'Kaynak sayısı'),
      description: t("How many resources this service has - optionally only those whose name contains a text or that are in one status.", 'Bu serviste kaç kaynak olduğu - istenirse yalnızca adı bir metni içerenler ya da belirli bir durumda olanlar.'),
      icon: 'number.square.fill',
      params: [
        { key: 'nameContains', label: t('Name contains (optional)', 'Ad şunu içerir (isteğe bağlı)'), type: 'text', maxLength: 200 },
        { key: 'status', label: t('Status (optional)', 'Durum (isteğe bağlı)'), type: 'combo', source: 'generic.statuses', maxLength: 100, hint: t('The statuses found in the list are offered.', 'Listede bulunan durumlar önerilir.') },
      ],
      async value(ctx) {
        return { value: filtered(await rows(service, ctx), ctx).length, unit: t('resources', 'kaynak') };
      },
      // The service's list, filtered by the same text where the screen has a filter field.
      // The service's list with the same search in its filter field (name and status words).
      link: (ctx) => ({ service, filter: [ctx.params.nameContains, ctx.params.status].filter((x) => x && x.trim()).join(' ') || undefined }),
      async preview(ctx) {
        const list = filtered(await rows(service, ctx), ctx);
        return {
          title: t(`Matching resources (${list.length})`, `Eşleşen kaynaklar (${list.length})`),
          columns: [t('Name', 'Ad'), t('Status', 'Durum')],
          rows: list.slice(0, 30).map((r) => [r.name || r.id, r.status]),
          more: list.length > 30,
          emptyMessage: t('No resources match.', 'Eşleşen kaynak yok.'),
        };
      },
    });
  }
  if (PAGE_SERVICES[service] && !PAGE_SERVICES[service].uncounted) {
    templates.push({
      id: 'generic.openResource',
      kind: 'link',
      name: t('Open a resource', 'Kaynak aç'),
      description: t('Shortcut to one resource of this service.', 'Bu servisin bir kaynağına kısayol.'),
      icon: 'arrow.up.right.square.fill',
      params: [{ key: 'resource', label: t('Resource', 'Kaynak'), type: 'combo', source: 'generic.resources', required: true, maxLength: 2048 }],
      link: (ctx) => ({ service, resource: ctx.params.resource }),
    });
  }
  templates.push({
    id: 'generic.openService',
    kind: 'link',
    name: t('Open service', 'Servisi aç'),
    description: t('Shortcut to this service in the app.', 'Uygulamada bu servise kısayol.'),
    icon: 'arrow.up.forward.app.fill',
    params: [],
    link: () => ({ service }),
  });
  return templates;
}
