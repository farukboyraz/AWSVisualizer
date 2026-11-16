import {
  Inspector2Client,
  BatchGetAccountStatusCommand,
  ListCoverageStatisticsCommand,
  ListCoverageCommand,
  ListFindingsCommand,
  ListFindingAggregationsCommand,
  GetConfigurationCommand,
  type Finding,
} from '@aws-sdk/client-inspector2';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, isNotEnabled } from './page-common.js';
import type { PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new Inspector2Client({ region: r, credentials: cachedCredentials(p) });

const FINDING_LIMIT = 100;
const COVERAGE_LIMIT = 500;

const ACTIVE = { findingStatus: [{ comparison: 'EQUALS' as const, value: 'ACTIVE' }] };

async function status(c: Inspector2Client) {
  return (await c.send(new BatchGetAccountStatusCommand({}))).accounts?.[0];
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const acct = await status(c);
  const state = acct?.state?.status;
  const scans = Object.entries(acct?.resourceState || {})
    .filter(([, v]) => v?.status === 'ENABLED')
    .map(([k]) => k);
  const rows: PageSummary[] = [{ id: 'acct:', name: 'Account status', status: state, info: scans.length ? `Scanning: ${scans.join(', ')}` : 'No scan types enabled' }];
  if (state === 'ENABLED' || state === 'ENABLING') {
    rows.push({ id: 'findings:', name: 'Active findings', info: `Highest severity first · first ${FINDING_LIMIT}` });
    rows.push({ id: 'coverage:', name: 'Coverage', info: 'Scanned EC2 instances, ECR repositories/images and Lambda functions' });
  }
  return rows;
}

const findingRow = (f: Finding) => [f.severity, f.title, f.type, f.resources?.[0]?.type, f.resources?.[0]?.id, f.inspectorScore, f.fixAvailable, f.exploitAvailable, f.lastObservedAt];

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const errors: string[] = [];
  if (id === 'acct:') {
    const parts = await settle(
      {
        acct: status(c),
        coverage: c.send(new ListCoverageStatisticsCommand({ groupBy: 'RESOURCE_TYPE' })),
        counts: c.send(new ListFindingAggregationsCommand({ aggregationType: 'ACCOUNT' })),
        config: c.send(new GetConfigurationCommand({})),
      },
      errors,
      isNotEnabled,
    );
    const sev = parts.counts?.responses?.[0]?.accountAggregation?.severityCounts;
    const rs = parts.acct?.resourceState;
    return {
      id,
      title: 'Amazon Inspector',
      subtitle: `Account ${parts.acct?.accountId ?? ''}`,
      status: parts.acct?.state?.status,
      tabs: [
        tab('Dashboard', {
          sections: [
            section('Active findings', [
              ['All', sev?.all ?? 0],
              ['Critical', sev?.critical ?? 0],
              ['High', sev?.high ?? 0],
              ['Medium', sev?.medium ?? 0],
            ]),
            section('Scan types', [
              ['EC2 scanning', rs?.ec2?.status],
              ['ECR scanning', rs?.ecr?.status],
              ['Lambda standard scanning', rs?.lambda?.status],
              ['Lambda code scanning', rs?.lambdaCode?.status],
            ]),
            section('Settings', [
              ['ECR re-scan duration', parts.config?.ecrConfiguration?.rescanDurationState?.rescanDuration],
              ['ECR pull-date re-scan duration', parts.config?.ecrConfiguration?.rescanDurationState?.pullDateRescanDuration],
              ['EC2 scan mode', parts.config?.ec2Configuration?.scanModeState?.scanMode],
            ]),
          ],
          tables: [
            table(['Resource type', 'Covered resources'], (parts.coverage?.countsByGroup || []).map((g) => [g.groupKey, g.count]), { title: `Coverage (${parts.coverage?.totalCounts ?? 0} resources)`, emptyMessage: 'No covered resources' }),
          ],
        }),
      ],
      actions: [],
      errors,
    };
  }
  if (id === 'findings:') {
    const res = await c.send(new ListFindingsCommand({ filterCriteria: ACTIVE, sortCriteria: { field: 'SEVERITY', sortOrder: 'DESC' }, maxResults: FINDING_LIMIT }));
    const findings = res.findings || [];
    const titles = await c.send(new ListFindingAggregationsCommand({ aggregationType: 'TITLE', aggregationRequest: { titleAggregation: { sortBy: 'ALL', sortOrder: 'DESC' } } })).catch((err) => (errors.push(`Top findings: ${err.message}`), undefined));
    return {
      id,
      title: 'Active findings',
      subtitle: res.nextToken ? `Highest severity first · first ${FINDING_LIMIT}` : `${findings.length} active findings`,
      tabs: [
        tab('Findings', {
          tables: [
            table(['Severity', 'Title', 'Type', 'Resource type', 'Resource', 'Inspector score', 'Fix available', 'Exploit available', 'Last observed'], findings.map(findingRow), { statusColumn: 0, emptyMessage: 'No active findings' }),
          ],
        }),
        tab('By vulnerability', {
          tables: [
            table(
              ['Title', 'Vulnerability', 'Critical', 'High', 'Medium', 'All'],
              (titles?.responses || []).map((r) => {
                const t = r.titleAggregation;
                return [t?.title, t?.vulnerabilityId, t?.severityCounts?.critical, t?.severityCounts?.high, t?.severityCounts?.medium, t?.severityCounts?.all];
              }),
              { emptyMessage: 'No findings' },
            ),
          ],
        }),
      ],
      actions: [],
      errors,
    };
  }
  if (id === 'coverage:') {
    const items = await pageAll((nextToken) => c.send(new ListCoverageCommand({ nextToken, maxResults: 200 })), (r) => r.coveredResources, (r) => r.nextToken, COVERAGE_LIMIT);
    return {
      id,
      title: 'Coverage',
      subtitle: items.length >= COVERAGE_LIMIT ? `First ${COVERAGE_LIMIT} resources` : `${items.length} resources`,
      tabs: [
        tab('Resources', {
          tables: [
            table(
              ['Resource', 'Type', 'Scan type', 'Status', 'Reason', 'Last scanned'],
              items.map((r) => [r.resourceId, r.resourceType, r.scanType, r.scanStatus?.statusCode, r.scanStatus?.reason, r.lastScannedAt]),
              { statusColumn: 3, emptyMessage: 'No covered resources' },
            ),
          ],
        }),
      ],
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown Inspector page: ${id}`, 400);
}

export const inspectorAdapter: PageServiceAdapter = {
  list,
  detail,
  uncounted: true,
};
