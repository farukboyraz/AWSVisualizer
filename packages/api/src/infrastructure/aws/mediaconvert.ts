import {
  MediaConvertClient,
  ListQueuesCommand,
  GetQueueCommand,
  ListJobTemplatesCommand,
  GetJobTemplateCommand,
  ListPresetsCommand,
  GetPresetCommand,
  ListJobsCommand,
  ListTagsForResourceCommand as McListTags,
  TagResourceCommand as McTag,
  UntagResourceCommand as McUntag,
} from '@aws-sdk/client-mediaconvert';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** MediaConvert. */
const mc = (p: string, r: string) => new MediaConvertClient(clientConfig(p, r));
const JOB_LIMIT = 50;

export const mediaConvertAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = mc(profile, region);
    const [queues, templates, presets] = await Promise.all([
      pageAll((NextToken) => c.send(new ListQueuesCommand({ NextToken })), (r) => r.Queues, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListJobTemplatesCommand({ NextToken, ListBy: 'NAME' })), (r) => r.JobTemplates, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListPresetsCommand({ NextToken, ListBy: 'NAME' })), (r) => r.Presets, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      { id: 'jobs:', name: 'Recent jobs', group: 'Jobs', info: `Most recent ${JOB_LIMIT}` },
      ...queues.map((q) => ({ id: `queue:${q.Name}`, name: q.Name || '', group: 'Queues', status: q.Status, info: `${q.PricingPlan} · ${q.ProgressingJobsCount ?? 0} running · ${q.SubmittedJobsCount ?? 0} waiting` })).sort(byName),
      // Only your own templates / presets - the system ones are the same for every account.
      ...templates.filter((t) => t.Type === 'CUSTOM').map((t) => ({ id: `tpl:${t.Name}`, name: t.Name || '', group: 'Job templates', info: t.Category || t.Description })).sort(byName),
      ...presets.filter((p) => p.Type === 'CUSTOM').map((p) => ({ id: `preset:${p.Name}`, name: p.Name || '', group: 'Output presets', info: p.Category || p.Description })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = mc(profile, region);
    const [kind, name] = splitId(id);
    const errors: string[] = [];
    const tags = async (arn?: string) => (arn ? (await settle({ t: c.send(new McListTags({ Arn: arn })) }, errors)).t?.ResourceTags?.Tags : undefined);
    if (kind === 'jobs') {
      const jobs = (await c.send(new ListJobsCommand({ MaxResults: JOB_LIMIT, Order: 'DESCENDING' }))).Jobs || [];
      return {
        id,
        title: 'Recent jobs',
        subtitle: `Most recent ${JOB_LIMIT}`,
        tabs: [
          tab('Jobs', {
            tables: [
              table(['Job', 'Status', 'Phase', 'Progress', 'Queue', 'Template', 'Created', 'Error'], jobs.map((j) => [j.Id, j.Status, j.CurrentPhase, j.JobPercentComplete !== undefined ? `${j.JobPercentComplete}%` : undefined, lastPart(j.Queue), lastPart(j.JobTemplate), j.CreatedAt, j.ErrorMessage]), {
                statusColumn: 1,
                emptyMessage: 'No jobs (MediaConvert keeps jobs for 90 days)',
              }),
            ],
          }),
        ],
        actions: [],
        errors,
      };
    }
    if (kind === 'queue') {
      const q = (await c.send(new GetQueueCommand({ Name: name }))).Queue;
      if (!q) throw httpError(`Queue not found: ${name}`, 404);
      const rp = q.ReservationPlan;
      return {
        id,
        title: name,
        subtitle: `${q.PricingPlan} queue`,
        status: q.Status,
        arn: q.Arn,
        tabs: [tab('Details', { sections: [section('Queue', [['Status', q.Status], ['Pricing', q.PricingPlan], ['Type', q.Type], ['Running jobs', q.ProgressingJobsCount], ['Waiting jobs', q.SubmittedJobsCount], ['Reserved slots', rp?.ReservedSlots], ['Reservation ends', rp?.ExpiresAt], ['Description', q.Description], ['Created', q.CreatedAt]])] })],
        tags: tagMap(await tags(q.Arn)),
        actions: [],
        errors,
      };
    }
    if (kind === 'tpl') {
      const t = (await c.send(new GetJobTemplateCommand({ Name: name }))).JobTemplate;
      if (!t) throw httpError(`Template not found: ${name}`, 404);
      const outputs = (t.Settings?.OutputGroups || []).map((g) => [g.Name ?? g.OutputGroupSettings?.Type, g.OutputGroupSettings?.Type, (g.Outputs || []).length]);
      return {
        id,
        title: name,
        subtitle: 'Job template',
        arn: t.Arn,
        tabs: [
          tab('Details', {
            sections: [section('Template', [['Category', t.Category], ['Description', t.Description], ['Queue', lastPart(t.Queue)], ['Priority', t.Priority], ['Acceleration', t.AccelerationSettings?.Mode], ['Created', t.CreatedAt], ['Updated', t.LastUpdated]])],
            tables: [table(['Output group', 'Type', 'Outputs'], outputs, { title: 'Output groups', emptyMessage: 'No output groups' })],
          }),
          tab('Settings', { json: JSON.stringify(t.Settings, null, 2) }),
        ],
        tags: tagMap(await tags(t.Arn)),
        actions: [],
        errors,
      };
    }
    if (kind === 'preset') {
      const p = (await c.send(new GetPresetCommand({ Name: name }))).Preset;
      if (!p) throw httpError(`Preset not found: ${name}`, 404);
      const v = p.Settings?.VideoDescription;
      return {
        id,
        title: name,
        subtitle: 'Output preset',
        arn: p.Arn,
        tabs: [
          tab('Details', { sections: [section('Preset', [['Category', p.Category], ['Description', p.Description], ['Container', p.Settings?.ContainerSettings?.Container], ['Video codec', v?.CodecSettings?.Codec], ['Resolution', v?.Width && v?.Height ? `${v.Width}×${v.Height}` : undefined], ['Audio tracks', p.Settings?.AudioDescriptions?.length], ['Created', p.CreatedAt]])] }),
          tab('Settings', { json: JSON.stringify(p.Settings, null, 2) }),
        ],
        tags: tagMap(await tags(p.Arn)),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown MediaConvert page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || id === 'jobs:') throw httpError('This page has no tags', 400);
    await mc(profile, region).send(new McTag({ Arn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || id === 'jobs:') throw httpError('This page has no tags', 400);
    await mc(profile, region).send(new McUntag({ Arn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id !== 'jobs:',
};
