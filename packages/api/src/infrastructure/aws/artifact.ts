import { ArtifactClient, ListReportsCommand, GetReportMetadataCommand, GetAccountSettingsCommand } from '@aws-sdk/client-artifact';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, tab, settle, httpError, pageAll } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** The AWS Artifact API is served from us-east-1. */
const client = (p: string) => new ArtifactClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

async function list(profile: string): Promise<PageSummary[]> {
  const reports = await pageAll((nextToken) => client(profile).send(new ListReportsCommand({ nextToken, maxResults: 300 })), (r) => r.reports, (r) => r.nextToken);
  return [
    { id: 'settings:', name: 'Account settings', info: 'Notification settings' },
    ...reports
      .map((r) => ({ id: `rep:${r.id}`, name: r.name || r.id || '', group: r.category || 'Reports', status: r.state, info: [r.series, r.companyName, r.version !== undefined && `v${r.version}`].filter(Boolean).join(' · ') }))
      .sort((a, b) => (a.group || '').localeCompare(b.group || '') || a.name.localeCompare(b.name)),
  ];
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const c = client(profile);
  const [kind, reportId] = splitId(id);
  if (kind === 'settings') {
    const errors: string[] = [];
    const { s } = await settle({ s: c.send(new GetAccountSettingsCommand({})) }, errors);
    return {
      id,
      title: 'AWS Artifact settings',
      tabs: [tab('Settings', { sections: [section('Account', [['Notification subscription', s?.accountSettings?.notificationSubscriptionStatus]])] })],
      actions: [],
      errors,
    };
  }
  if (kind !== 'rep') throw httpError(`Unknown Artifact page: ${id}`, 400);
  const r = (await c.send(new GetReportMetadataCommand({ reportId }))).reportDetails;
  if (!r) throw httpError(`Report not found: ${reportId}`, 404);
  return {
    id,
    title: r.name || reportId,
    subtitle: r.category,
    status: r.state,
    arn: r.arn,
    tabs: [
      tab('Details', {
        sections: [
          section(
            'Report',
            [
              ['Name', r.name],
              ['Description', r.description],
              ['Category', r.category],
              ['Series', r.series],
              ['Company', r.companyName],
              ['Product', r.productName],
              ['Version', r.version],
              ['Period', r.periodStart || r.periodEnd ? `${r.periodStart?.toISOString().slice(0, 10) ?? '?'} – ${r.periodEnd?.toISOString().slice(0, 10) ?? '?'}` : undefined],
              ['Published', r.createdAt],
              ['Last modified', r.lastModifiedAt],
              ['Acceptance', r.acceptanceType === 'EXPLICIT' ? 'Terms must be accepted before download' : r.acceptanceType === 'PASSTHROUGH' ? 'No separate terms' : r.acceptanceType],
              ['Terms', r.termArn],
              ['State', r.state],
              ['Upload state', r.uploadState],
              ['Status message', r.statusMessage],
            ],
            { note: 'Downloading a report may require accepting its terms in the AWS Artifact console; this app only shows report metadata.' },
          ),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

export const artifactAdapter: PageServiceAdapter = { list, detail, uncounted: true };
