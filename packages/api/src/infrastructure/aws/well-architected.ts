import {
  WellArchitectedClient,
  ListWorkloadsCommand,
  GetWorkloadCommand,
  ListLensReviewsCommand,
  ListMilestonesCommand,
  ListWorkloadSharesCommand,
  ListLensesCommand,
  GetLensCommand,
  ListLensSharesCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-wellarchitected';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new WellArchitectedClient({ region: r, credentials: cachedCredentials(p) });

const risks = (r?: Partial<Record<string, number>>) => (r ? `${r.HIGH ?? 0} high · ${r.MEDIUM ?? 0} medium risks` : undefined);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [workloads, lenses] = await Promise.all([
    pageAll((NextToken) => c.send(new ListWorkloadsCommand({ NextToken })), (r) => r.WorkloadSummaries, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListLensesCommand({ NextToken, LensType: 'CUSTOM_SELF' })), (r) => r.LensSummaries, (r) => r.NextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...workloads.map((w) => ({ id: `wl:${w.WorkloadId}`, name: w.WorkloadName || '', group: 'Workloads', status: w.ImprovementStatus, info: [risks(w.RiskCounts), `${w.Lenses?.length ?? 0} lenses`].filter(Boolean).join(' · ') })).sort(byName),
    ...lenses.map((l) => ({ id: `lens:${l.LensArn}`, name: l.LensName || '', group: 'Custom lenses', status: l.LensStatus, info: [l.LensVersion && `v${l.LensVersion}`, l.Description].filter(Boolean).join(' · ') })).sort(byName),
  ];
}

async function workloadPage(c: WellArchitectedClient, id: string, workloadId: string): Promise<ResourcePage> {
  const w = (await c.send(new GetWorkloadCommand({ WorkloadId: workloadId }))).Workload;
  if (!w) throw httpError(`Workload not found: ${workloadId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      reviews: pageAll((NextToken) => c.send(new ListLensReviewsCommand({ WorkloadId: workloadId, NextToken })), (r) => r.LensReviewSummaries, (r) => r.NextToken),
      milestones: pageAll((NextToken) => c.send(new ListMilestonesCommand({ WorkloadId: workloadId, NextToken })), (r) => r.MilestoneSummaries, (r) => r.NextToken),
      shares: pageAll((NextToken) => c.send(new ListWorkloadSharesCommand({ WorkloadId: workloadId, NextToken })), (r) => r.WorkloadShareSummaries, (r) => r.NextToken),
    },
    errors,
  );
  const rc = w.RiskCounts || {};
  return {
    id,
    title: w.WorkloadName || workloadId,
    subtitle: w.Description || 'Workload',
    status: w.ImprovementStatus,
    arn: w.WorkloadArn,
    tabs: [
      tab('Overview', {
        sections: [
          section('Workload', [
            ['Name', w.WorkloadName],
            ['Environment', w.Environment],
            ['Review owner', w.ReviewOwner],
            ['Owner account', w.Owner],
            ['Industry', [w.IndustryType, w.Industry].filter(Boolean).join(' / ')],
            ['AWS regions', w.AwsRegions],
            ['Non-AWS regions', w.NonAwsRegions],
            ['Account IDs', w.AccountIds],
            ['Architectural design', w.ArchitecturalDesign],
            ['Pillar priorities', w.PillarPriorities],
            ['Applications', w.Applications],
            ['Profiles', (w.Profiles || []).map((p) => p.ProfileArn?.split('/').pop())],
            ['Updated', w.UpdatedAt],
          ]),
          section('Risks', [
            ['High', rc.HIGH],
            ['Medium', rc.MEDIUM],
            ['None', rc.NONE],
            ['Unanswered', rc.UNANSWERED],
            ['Not applicable', rc.NOT_APPLICABLE],
            ['Improvement status', w.ImprovementStatus],
          ]),
        ],
      }),
      tab('Lenses', {
        tables: [table(['Lens', 'Version', 'Status', 'Risks', 'Updated'], (parts.reviews || []).map((l) => [l.LensName, l.LensVersion, l.LensStatus, risks(l.RiskCounts), l.UpdatedAt]), { statusColumn: 2, emptyMessage: 'No lenses applied' })],
      }),
      tab('Milestones', {
        tables: [table(['#', 'Milestone', 'Recorded', 'Risks then'], (parts.milestones || []).map((m) => [m.MilestoneNumber, m.MilestoneName, m.RecordedAt, risks(m.WorkloadSummary?.RiskCounts)]), { emptyMessage: 'No milestones saved' })],
      }),
      tab('Shares', {
        tables: [table(['Shared with', 'Permission', 'Status', 'Message'], (parts.shares || []).map((s) => [s.SharedWith, s.PermissionType, s.Status, s.StatusMessage]), { statusColumn: 2, emptyMessage: 'Not shared' })],
      }),
      ...(w.Notes ? [tab('Notes', { text: w.Notes })] : []),
    ],
    tags: tagMap(w.Tags),
    actions: [],
    errors,
  };
}

async function lensPage(c: WellArchitectedClient, id: string, arn: string): Promise<ResourcePage> {
  const l = (await c.send(new GetLensCommand({ LensAlias: arn }))).Lens;
  if (!l) throw httpError(`Lens not found: ${arn}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      shares: pageAll((NextToken) => c.send(new ListLensSharesCommand({ LensAlias: arn, NextToken })), (r) => r.LensShareSummaries, (r) => r.NextToken),
      tags: c.send(new ListTagsForResourceCommand({ WorkloadArn: arn })),
    },
    errors,
  );
  return {
    id,
    title: l.Name || arn,
    subtitle: l.Description || 'Custom lens',
    arn,
    tabs: [
      tab('Details', {
        sections: [section('Lens', [['Name', l.Name], ['Version', l.LensVersion], ['Owner', l.Owner], ['Share invitation', l.ShareInvitationId]])],
        tables: [table(['Shared with', 'Status', 'Message'], (parts.shares || []).map((s) => [s.SharedWith, s.Status, s.StatusMessage]), { title: 'Shares', statusColumn: 1, emptyMessage: 'Not shared' })],
      }),
    ],
    tags: tagMap(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'wl') return workloadPage(c, id, rest);
  if (kind === 'lens') return lensPage(c, id, rest);
  throw httpError(`Unknown Well-Architected page: ${id}`, 400);
}

export const wellArchitectedAdapter: PageServiceAdapter = {
  list,
  detail,
  // The Tag APIs name the parameter WorkloadArn but accept lens ARNs too.
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ WorkloadArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ WorkloadArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('wl:'),
};
