import {
  DataPipelineClient,
  ListPipelinesCommand,
  DescribePipelinesCommand,
  GetPipelineDefinitionCommand,
  AddTagsCommand,
  RemoveTagsCommand,
  type Field,
} from '@aws-sdk/client-data-pipeline';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new DataPipelineClient({ region: r, credentials: cachedCredentials(p) });

/** Data Pipeline marks encrypted fields with a leading `*` (e.g. `*password`); those and secret-looking keys are never shown. */
const SECRET_KEY = /^\*|pass(word)?|secret|token|credential|private.?key|\bkey\b/i;
const fieldValue = (f: Field) => (SECRET_KEY.test(f.key || '') ? '•••• (hidden)' : f.stringValue ?? (f.refValue ? `→ ${f.refValue}` : undefined));
const field = (fields: Field[] | undefined, key: string) => fields?.find((f) => f.key === key)?.stringValue;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const ids = await pageAll((marker) => c.send(new ListPipelinesCommand({ marker })).then((r) => ({ ...r, next: r.hasMoreResults ? r.marker : undefined })), (r) => r.pipelineIdList, (r) => r.next);
  const chunks = Array.from({ length: Math.ceil(ids.length / 25) }, (_, i) => ids.slice(i * 25, i * 25 + 25).map((x) => x.id || ''));
  const described = (await mapLimited(chunks, 3, (pipelineIds) => c.send(new DescribePipelinesCommand({ pipelineIds })).then((r) => r.pipelineDescriptionList || []))).flat();
  return described
    .map((p) => ({ id: `pl:${p.pipelineId}`, name: p.name || p.pipelineId || '', status: field(p.fields, '@pipelineState'), info: [field(p.fields, '@healthStatus') && `health ${field(p.fields, '@healthStatus')}`, field(p.fields, '@latestRunTime') && `last run ${field(p.fields, '@latestRunTime')}`].filter(Boolean).join(' · ') }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, pipelineId] = splitId(id);
  if (kind !== 'pl') throw httpError(`Unknown Data Pipeline page: ${id}`, 400);
  const c = client(profile, region);
  const p = (await c.send(new DescribePipelinesCommand({ pipelineIds: [pipelineId] }))).pipelineDescriptionList?.[0];
  if (!p) throw httpError(`Pipeline not found: ${pipelineId}`, 404);
  const errors: string[] = [];
  const { def } = await settle({ def: c.send(new GetPipelineDefinitionCommand({ pipelineId })) }, errors);
  const objects = def?.pipelineObjects || [];
  return {
    id,
    title: p.name || pipelineId,
    subtitle: p.description || 'Data Pipeline',
    status: field(p.fields, '@pipelineState'),
    tabs: [
      tab('Details', {
        sections: [
          section(
            'Pipeline',
            [
              ['Pipeline ID', p.pipelineId],
              ['State', field(p.fields, '@pipelineState')],
              ['Health', field(p.fields, '@healthStatus')],
              ['Created', field(p.fields, '@creationTime')],
              ['Last run', field(p.fields, '@latestRunTime')],
              ['Next scheduled run', field(p.fields, '@nextRunTime')],
              ['Scheduled start', field(p.fields, '@scheduledStartTime')],
              ['Owner', field(p.fields, '@userId') ?? field(p.fields, 'pipelineCreator')],
            ],
            { note: 'AWS Data Pipeline is in maintenance mode and closed to new customers.' },
          ),
        ],
      }),
      tab('Definition', {
        tables: [
          table(
            ['Object', 'Type', 'Fields'],
            objects.map((o) => [o.name || o.id, field(o.fields, 'type'), (o.fields || []).filter((f) => f.key !== 'type').map((f) => `${f.key}=${fieldValue(f)}`).join('; ')]),
            { title: `${objects.length} objects`, emptyMessage: 'No definition' },
          ),
          table(['Parameter', 'Value'], (def?.parameterValues || []).map((v) => [v.id, SECRET_KEY.test(v.id || '') ? '•••• (hidden)' : v.stringValue]), { title: 'Parameter values', emptyMessage: 'No parameters' }),
        ],
      }),
    ],
    tags: (p.tags || []).map((t) => ({ key: t.key || '', value: t.value || '' })),
    actions: [],
    errors,
  };
}

export const dataPipelineAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new AddTagsCommand({ pipelineId: splitId(id)[1], tags: [{ key, value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new RemoveTagsCommand({ pipelineId: splitId(id)[1], tagKeys: [key] }));
  },
};
