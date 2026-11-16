import {
  ControlTowerClient,
  ListLandingZonesCommand,
  GetLandingZoneCommand,
  ListLandingZoneOperationsCommand,
  ListEnabledBaselinesCommand,
  GetEnabledBaselineCommand,
  ListEnabledControlsCommand,
  GetEnabledControlCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-controltower';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ControlTowerClient({ region: r, credentials: cachedCredentials(p) });

const errName = (err: unknown) => (err as { name?: string })?.name;
/** Not the Control Tower home region / not set up: an empty list, not a failure. */
const notSetUp = (err: unknown) => ['AccessDeniedException', 'ResourceNotFoundException', 'ValidationException'].includes(errName(err) || '');

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  let zones;
  try {
    zones = await pageAll((nextToken) => c.send(new ListLandingZonesCommand({ nextToken })), (r) => r.landingZones, (r) => r.nextToken);
  } catch (err) {
    if (notSetUp(err)) return [];
    throw err;
  }
  const [baselines, controls] = await Promise.all([
    pageAll((nextToken) => c.send(new ListEnabledBaselinesCommand({ nextToken })), (r) => r.enabledBaselines, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => c.send(new ListEnabledControlsCommand({ nextToken })), (r) => r.enabledControls, (r) => r.nextToken).catch(() => []),
  ]);
  return [
    ...zones.map((z) => ({ id: `lz:${z.arn}`, name: 'Landing zone', group: 'Landing zone', info: lastPart(z.arn) })),
    ...baselines.map((b) => ({ id: `bl:${b.arn}`, name: lastPart(b.baselineIdentifier) || '', group: 'Enabled baselines', status: b.statusSummary?.status, info: `${lastPart(b.targetIdentifier)} · v${b.baselineVersion ?? '-'}` })),
    ...controls
      .map((x) => ({ id: `ctl:${x.arn}`, name: lastPart(x.controlIdentifier) || '', group: 'Enabled controls', status: x.statusSummary?.status, info: [`on ${lastPart(x.targetIdentifier)}`, x.driftStatusSummary?.driftStatus && `drift ${x.driftStatusSummary.driftStatus}`].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function landingZonePage(c: ControlTowerClient, id: string, arn: string): Promise<ResourcePage> {
  const z = (await c.send(new GetLandingZoneCommand({ landingZoneIdentifier: arn }))).landingZone;
  if (!z) throw httpError(`Landing zone not found: ${arn}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      ops: c.send(new ListLandingZoneOperationsCommand({ maxResults: 25 })),
      tags: c.send(new ListTagsForResourceCommand({ resourceArn: arn })),
    },
    errors,
  );
  const manifest = z.manifest as Record<string, unknown> | undefined;
  return {
    id,
    title: 'Landing zone',
    subtitle: `Version ${z.version ?? '-'}`,
    status: z.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Landing zone', [
            ['Status', z.status],
            ['Version', z.version],
            ['Latest available version', z.latestAvailableVersion],
            ['Drift status', z.driftStatus?.status],
            ['Governed regions', (manifest?.governedRegions as string[] | undefined) ?? undefined],
          ]),
        ],
      }),
      tab('Operations', {
        tables: [table(['Operation', 'Type', 'Status'], (parts.ops?.landingZoneOperations || []).map((o) => [lastPart(o.operationIdentifier), o.operationType, o.status]), { statusColumn: 2, emptyMessage: 'No operations' })],
      }),
      ...(manifest ? [tab('Manifest', { json: JSON.stringify(manifest, null, 2) })] : []),
    ],
    tags: tagMap(parts.tags?.tags),
    actions: [],
    errors,
  };
}

async function baselinePage(c: ControlTowerClient, id: string, arn: string): Promise<ResourcePage> {
  const b = (await c.send(new GetEnabledBaselineCommand({ enabledBaselineIdentifier: arn }))).enabledBaselineDetails;
  if (!b) throw httpError(`Enabled baseline not found: ${arn}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ resourceArn: arn })) }, errors);
  return {
    id,
    title: lastPart(b.baselineIdentifier) || arn,
    subtitle: `Baseline on ${lastPart(b.targetIdentifier)}`,
    status: b.statusSummary?.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Enabled baseline', [
            ['Baseline', b.baselineIdentifier],
            ['Version', b.baselineVersion],
            ['Target', b.targetIdentifier],
            ['Status', b.statusSummary?.status],
            ['Last operation', b.statusSummary?.lastOperationIdentifier],
          ]),
        ],
        tables: [table(['Parameter', 'Value'], (b.parameters || []).map((p) => [p.key, JSON.stringify(p.value)]), { title: 'Parameters', emptyMessage: 'No parameters' })],
      }),
    ],
    tags: tagMap(tags?.tags),
    actions: [],
    errors,
  };
}

async function controlPage(c: ControlTowerClient, id: string, arn: string): Promise<ResourcePage> {
  const x = (await c.send(new GetEnabledControlCommand({ enabledControlIdentifier: arn }))).enabledControlDetails;
  if (!x) throw httpError(`Enabled control not found: ${arn}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ resourceArn: arn })) }, errors);
  return {
    id,
    title: lastPart(x.controlIdentifier) || arn,
    subtitle: `Control on ${lastPart(x.targetIdentifier)}`,
    status: x.statusSummary?.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Enabled control', [
            ['Control', x.controlIdentifier],
            ['Target', x.targetIdentifier],
            ['Status', x.statusSummary?.status],
            ['Drift', x.driftStatusSummary?.driftStatus],
            ['Regions', (x.targetRegions || []).map((r) => r.name)],
          ]),
        ],
        tables: [table(['Parameter', 'Value'], (x.parameters || []).map((p) => [p.key, JSON.stringify(p.value)]), { title: 'Parameters', emptyMessage: 'No parameters' })],
      }),
    ],
    tags: tagMap(tags?.tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'lz') return landingZonePage(c, id, arn);
  if (kind === 'bl') return baselinePage(c, id, arn);
  if (kind === 'ctl') return controlPage(c, id, arn);
  throw httpError(`Unknown Control Tower page: ${id}`, 400);
}

export const controlTowerAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ resourceArn: splitId(id)[1], tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: splitId(id)[1], tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('ctl:'),
};
