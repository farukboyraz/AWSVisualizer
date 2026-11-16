import {
  GuardDutyClient,
  ListDetectorsCommand,
  GetDetectorCommand,
  ListFindingsCommand,
  GetFindingsCommand,
  GetFindingsStatisticsCommand,
  ListFiltersCommand,
  ListIPSetsCommand,
  GetIPSetCommand,
  ListThreatIntelSetsCommand,
  GetThreatIntelSetCommand,
  ListMembersCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-guardduty';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, tagMap, accountId } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new GuardDutyClient({ region: r, credentials: cachedCredentials(p) });

/** Newest-highest-severity findings shown on the page. */
const FINDING_LIMIT = 50;

export const severityLabel = (s?: number) => (s === undefined ? '-' : s >= 9 ? 'Critical' : s >= 7 ? 'High' : s >= 4 ? 'Medium' : 'Low');

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const ids = await pageAll((NextToken) => c.send(new ListDetectorsCommand({ NextToken })), (r) => r.DetectorIds, (r) => r.NextToken);
  return mapLimited(ids, 3, async (id) => {
    const d = await c.send(new GetDetectorCommand({ DetectorId: id })).catch(() => undefined);
    return { id, name: `Detector ${id.slice(0, 8)}…`, status: d?.Status, info: [id, d?.FindingPublishingFrequency && `publishes ${d.FindingPublishingFrequency}`].filter(Boolean).join(' · ') };
  });
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const d = await c.send(new GetDetectorCommand({ DetectorId: id }));
  const errors: string[] = [];
  const parts = await settle(
    {
      findingIds: c.send(
        new ListFindingsCommand({
          DetectorId: id,
          MaxResults: FINDING_LIMIT,
          FindingCriteria: { Criterion: { 'service.archived': { Equals: ['false'] } } },
          SortCriteria: { AttributeName: 'updatedAt', OrderBy: 'DESC' },
        }),
      ),
      stats: c.send(new GetFindingsStatisticsCommand({ DetectorId: id, FindingStatisticTypes: ['COUNT_BY_SEVERITY'], FindingCriteria: { Criterion: { 'service.archived': { Equals: ['false'] } } } })),
      filters: pageAll((NextToken) => c.send(new ListFiltersCommand({ DetectorId: id, NextToken })), (r) => r.FilterNames, (r) => r.NextToken),
      ipSets: pageAll((NextToken) => c.send(new ListIPSetsCommand({ DetectorId: id, NextToken })), (r) => r.IpSetIds, (r) => r.NextToken),
      threatSets: pageAll((NextToken) => c.send(new ListThreatIntelSetsCommand({ DetectorId: id, NextToken })), (r) => r.ThreatIntelSetIds, (r) => r.NextToken),
      members: pageAll((NextToken) => c.send(new ListMembersCommand({ DetectorId: id, NextToken })), (r) => r.Members, (r) => r.NextToken),
      account: accountId(profile, region),
    },
    errors,
  );
  const [findings, ipSets, threatSets] = await Promise.all([
    parts.findingIds?.FindingIds?.length
      ? c.send(new GetFindingsCommand({ DetectorId: id, FindingIds: parts.findingIds.FindingIds })).then((r) => r.Findings || []).catch((err) => (errors.push(`Findings: ${err.message}`), []))
      : Promise.resolve([]),
    mapLimited(parts.ipSets || [], 5, (s) => c.send(new GetIPSetCommand({ DetectorId: id, IpSetId: s })).catch(() => undefined)),
    mapLimited(parts.threatSets || [], 5, (s) => c.send(new GetThreatIntelSetCommand({ DetectorId: id, ThreatIntelSetId: s })).catch(() => undefined)),
  ]);
  findings.sort((a, b) => (b.Severity ?? 0) - (a.Severity ?? 0));
  const bySeverity: Record<string, number> = {};
  for (const [sev, n] of Object.entries(parts.stats?.FindingStatistics?.CountBySeverity || {})) bySeverity[severityLabel(Number(sev))] = (bySeverity[severityLabel(Number(sev))] ?? 0) + n;
  return {
    id,
    title: `GuardDuty detector`,
    subtitle: id,
    status: d.Status,
    arn: parts.account ? `arn:aws:guardduty:${region}:${parts.account}:detector/${id}` : undefined,
    tabs: [
      tab('Summary', {
        sections: [
          section('Detector', [
            ['Detector ID', id],
            ['Status', d.Status],
            ['Finding publishing frequency', d.FindingPublishingFrequency],
            ['Service role', d.ServiceRole],
            ['Created', d.CreatedAt],
            ['Updated', d.UpdatedAt],
          ]),
          section('Active findings by severity', [
            ['Critical', bySeverity.Critical ?? 0],
            ['High', bySeverity.High ?? 0],
            ['Medium', bySeverity.Medium ?? 0],
            ['Low', bySeverity.Low ?? 0],
          ]),
        ],
      }),
      tab('Findings', {
        tables: [
          table(
            ['Severity', 'Finding type', 'Title', 'Resource', 'Count', 'Last seen'],
            findings.map((f) => [severityLabel(f.Severity), f.Type, f.Title, f.Resource?.ResourceType, f.Service?.Count, f.UpdatedAt]),
            { title: `Latest ${FINDING_LIMIT} active findings`, statusColumn: 0, emptyMessage: 'No active findings' },
          ),
        ],
      }),
      tab('Protection plans', {
        tables: [
          table(
            ['Feature', 'Status', 'Additional configuration', 'Updated'],
            (d.Features || []).map((f) => [f.Name, f.Status, (f.AdditionalConfiguration || []).map((a) => `${a.Name}: ${a.Status}`), f.UpdatedAt]),
            { statusColumn: 1, emptyMessage: 'No feature configuration returned' },
          ),
        ],
      }),
      tab('Lists & filters', {
        tables: [
          table(['Trusted IP list', 'Format', 'Location', 'Status'], ipSets.map((s) => [s?.Name, s?.Format, s?.Location, s?.Status]), { title: 'Trusted IP lists', statusColumn: 3, emptyMessage: 'No trusted IP lists' }),
          table(['Threat list', 'Format', 'Location', 'Status'], threatSets.map((s) => [s?.Name, s?.Format, s?.Location, s?.Status]), { title: 'Threat lists', statusColumn: 3, emptyMessage: 'No threat lists' }),
          table(['Filter / suppression rule'], (parts.filters || []).map((f) => [f]), { title: 'Saved filters and suppression rules', emptyMessage: 'No saved filters' }),
        ],
      }),
      tab('Accounts', {
        tables: [
          table(['Account', 'Email', 'Relationship', 'Detector', 'Invited', 'Updated'], (parts.members || []).map((m) => [m.AccountId, m.Email, m.RelationshipStatus, m.DetectorId, m.InvitedAt, m.UpdatedAt]), { statusColumn: 2, emptyMessage: 'No member accounts' }),
        ],
      }),
    ],
    tags: tagMap(d.Tags),
    actions: [],
    errors,
  };
}

export const guardDutyAdapter: PageServiceAdapter = singleKind('detector', {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Detector ARN unknown', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Detector ARN unknown', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
});
