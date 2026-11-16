import {
  CodeBuildClient,
  ListProjectsCommand,
  BatchGetProjectsCommand,
  ListBuildsForProjectCommand,
  BatchGetBuildsCommand,
  ListReportGroupsCommand,
  BatchGetReportGroupsCommand,
  ListReportsForReportGroupCommand,
  BatchGetReportsCommand,
  UpdateProjectCommand,
  UpdateReportGroupCommand,
  type Project,
  type Tag,
  type Build,
  type Report,
} from '@aws-sdk/client-codebuild';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new CodeBuildClient({ region: r, credentials: cachedCredentials(p) });

const BUILD_LIMIT = 25;
/** Plaintext environment variables with these names are shown masked. */
const SECRET_NAME = /pass(word)?|secret|token|credential|private.?key|api.?key|\bkey\b|pwd/i;

const tags = (t?: Tag[]) => (t || []).map((x) => ({ key: x.key || '', value: x.value || '' }));
const seconds = (a?: Date, b?: Date) => (a && b ? Math.round((b.getTime() - a.getTime()) / 1000) : undefined);
const duration = (s?: number) => (s === undefined ? undefined : s >= 60 ? `${Math.floor(s / 60)} min ${s % 60} s` : `${s} s`);

async function getProject(c: CodeBuildClient, name: string): Promise<Project> {
  const p = (await c.send(new BatchGetProjectsCommand({ names: [name] }))).projects?.[0];
  if (!p) throw httpError(`Build project not found: ${name}`, 404);
  return p;
}

async function recentBuilds(c: CodeBuildClient, projectName: string): Promise<Build[]> {
  const r = await c.send(new ListBuildsForProjectCommand({ projectName, sortOrder: 'DESCENDING' }));
  const ids = (r.ids || []).slice(0, BUILD_LIMIT);
  return ids.length ? (await c.send(new BatchGetBuildsCommand({ ids }))).builds || [] : [];
}

async function recentReports(c: CodeBuildClient, reportGroupArn: string): Promise<Report[]> {
  const r = await c.send(new ListReportsForReportGroupCommand({ reportGroupArn, sortOrder: 'DESCENDING', maxResults: BUILD_LIMIT }));
  return r.reports?.length ? (await c.send(new BatchGetReportsCommand({ reportArns: r.reports }))).reports || [] : [];
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [names, groupArns] = await Promise.all([
    pageAll((nextToken) => c.send(new ListProjectsCommand({ nextToken, sortBy: 'NAME' })), (r) => r.projects, (r) => r.nextToken),
    pageAll((nextToken) => c.send(new ListReportGroupsCommand({ nextToken })), (r) => r.reportGroups, (r) => r.nextToken).catch(() => [] as string[]),
  ]);
  const chunks = <T>(xs: T[], n: number) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));
  const projects = (await mapLimited(chunks(names, 100), 3, (batch) => c.send(new BatchGetProjectsCommand({ names: batch })).then((r) => r.projects || []))).flat();
  const groups = groupArns.length ? (await mapLimited(chunks(groupArns, 100), 3, (batch) => c.send(new BatchGetReportGroupsCommand({ reportGroupArns: batch })).then((r) => r.reportGroups || []))).flat() : [];
  return [
    ...projects.map((p) => ({ id: `proj:${p.name}`, name: p.name || '', group: 'Build projects', info: [p.source?.type, p.environment?.computeType?.replace('BUILD_GENERAL1_', ''), p.environment?.image].filter(Boolean).join(' · ') })),
    ...groups.map((g) => ({ id: `rg:${g.arn}`, name: g.name || '', group: 'Report groups', status: g.status, info: g.type })).sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function projectPage(c: CodeBuildClient, id: string, name: string): Promise<ResourcePage> {
  const p = await getProject(c, name);
  const errors: string[] = [];
  const { builds } = await settle(
    {
      builds: recentBuilds(c, name),
    },
    errors,
  );
  const env = p.environment;
  const last = builds?.[0];
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Project', [
          ['Name', p.name],
          ['Description', p.description],
          ['Service role', p.serviceRole],
          ['Timeout (min)', p.timeoutInMinutes],
          ['Queued timeout (min)', p.queuedTimeoutInMinutes],
          ['Concurrent build limit', p.concurrentBuildLimit],
          ['Visibility', p.projectVisibility],
          ['Encryption key', p.encryptionKey],
          ['Badge', p.badge?.badgeEnabled ? p.badge.badgeRequestUrl : undefined],
          ['Created', p.created],
          ['Modified', p.lastModified],
        ]),
        section('Source', [
          ['Type', p.source?.type],
          ['Location', p.source?.location],
          ['Version', p.sourceVersion],
          ['Clone depth', p.source?.gitCloneDepth],
          ['Buildspec', p.source?.buildspec && !p.source.buildspec.includes('\n') ? p.source.buildspec : p.source?.buildspec ? 'Inline (see Buildspec tab)' : 'buildspec.yml in the source'],
          ['Report build status', p.source?.reportBuildStatus],
          ['Credentials', p.source?.auth?.resource],
          ['Secondary sources', (p.secondarySources || []).map((s) => `${s.sourceIdentifier}: ${s.type} ${s.location ?? ''}`)],
        ]),
        section('Artifacts & logs', [
          ['Artifacts', p.artifacts?.type === 'NO_ARTIFACTS' ? 'None' : `${p.artifacts?.type} ${p.artifacts?.location ?? ''}`],
          ['Cache', p.cache?.type === 'NO_CACHE' ? 'None' : `${p.cache?.type} ${p.cache?.location ?? (p.cache?.modes || []).join(', ')}`],
          ['CloudWatch Logs', p.logsConfig?.cloudWatchLogs?.status === 'ENABLED' ? `${p.logsConfig.cloudWatchLogs.groupName ?? 'default group'}${p.logsConfig.cloudWatchLogs.streamName ? ` / ${p.logsConfig.cloudWatchLogs.streamName}` : ''}` : 'Disabled'],
          ['S3 logs', p.logsConfig?.s3Logs?.status === 'ENABLED' ? p.logsConfig.s3Logs.location : 'Disabled'],
          ['VPC', p.vpcConfig?.vpcId],
          ['Subnets', p.vpcConfig?.subnets],
        ]),
        ...(p.webhook
          ? [
              section('Webhook', [
                ['Payload URL', p.webhook.payloadUrl],
                ['Build type', p.webhook.buildType],
                ['Filters', (p.webhook.filterGroups || []).map((g) => (g || []).map((f) => `${f.type}${f.excludeMatchedPattern ? ' !' : ' '}${f.pattern}`).join(' & '))],
                ['Secret rotated', p.webhook.lastModifiedSecret],
              ]),
            ]
          : []),
      ],
    }),
    tab('Environment', {
      sections: [
        section('Build environment', [
          ['Type', env?.type],
          ['Image', env?.image],
          ['Compute', env?.computeType],
          ['Fleet', env?.fleet?.fleetArn],
          ['Privileged mode', env?.privilegedMode],
          ['Image pull credentials', env?.imagePullCredentialsType],
          ['Registry credential', env?.registryCredential?.credential],
          ['Certificate', env?.certificate],
        ]),
      ],
      tables: [
        table(
          ['Variable', 'Type', 'Value'],
          (env?.environmentVariables || []).map((v) => [v.name, v.type ?? 'PLAINTEXT', (v.type ?? 'PLAINTEXT') === 'PLAINTEXT' && SECRET_NAME.test(v.name || '') ? '•••• (hidden)' : v.value]),
          { title: 'Environment variables', emptyMessage: 'No environment variables' },
        ),
      ],
    }),
    tab('Build history', {
      tables: [
        table(
          ['#', 'Status', 'Started', 'Duration', 'Source version', 'Initiator', 'Phase'],
          (builds || []).map((b) => [b.buildNumber, b.buildStatus, b.startTime, duration(seconds(b.startTime, b.endTime)), b.resolvedSourceVersion?.slice(0, 12) || b.sourceVersion, b.initiator, b.currentPhase]),
          { statusColumn: 1, title: `Last ${BUILD_LIMIT} builds`, emptyMessage: 'Never built' },
        ),
      ],
    }),
  ];
  if (last) {
    tabs.push(
      tab(`Build #${last.buildNumber ?? ''}`, {
        sections: [section('Latest build', [['Status', last.buildStatus], ['Started', last.startTime], ['Ended', last.endTime], ['Logs', last.logs?.deepLink], ['Reports', (last.reportArns || []).map(lastPart)]])],
        tables: [table(['Phase', 'Status', 'Duration', 'Message'], (last.phases || []).map((ph) => [ph.phaseType, ph.phaseStatus, duration(ph.durationInSeconds), (ph.contexts || []).map((x) => x.message).filter(Boolean).join(' ')]), { statusColumn: 1, title: 'Phases' })],
      }),
    );
  }
  if (p.source?.buildspec?.includes('\n')) tabs.push(tab('Buildspec', { text: p.source.buildspec }));
  return { id, title: name, subtitle: p.description || 'Build project', status: last?.buildStatus, arn: p.arn, tabs, tags: tags(p.tags), actions: [], errors };
}

async function reportGroupPage(c: CodeBuildClient, id: string, arn: string): Promise<ResourcePage> {
  const g = (await c.send(new BatchGetReportGroupsCommand({ reportGroupArns: [arn] }))).reportGroups?.[0];
  if (!g) throw httpError(`Report group not found: ${arn}`, 404);
  const errors: string[] = [];
  const { reports } = await settle(
    {
      reports: recentReports(c, arn),
    },
    errors,
  );
  return {
    id,
    title: g.name || arn,
    subtitle: `${g.type ?? ''} report group`,
    status: g.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [section('Report group', [['Name', g.name], ['Type', g.type], ['Status', g.status], ['Export', g.exportConfig?.exportConfigType === 'S3' ? `s3://${g.exportConfig.s3Destination?.bucket}/${g.exportConfig.s3Destination?.path ?? ''}` : 'None'], ['Created', g.created], ['Modified', g.lastModified]])],
      }),
      tab('Reports', {
        tables: [
          table(
            ['Report', 'Status', 'Created', 'Tests', 'Passed', 'Failed', 'Line coverage'],
            (reports || []).map((r) => [lastPart(r.arn), r.status, r.created, r.testSummary?.total, r.testSummary?.statusCounts?.SUCCEEDED, r.testSummary?.statusCounts?.FAILED, r.codeCoverageSummary?.lineCoveragePercentage !== undefined ? `${r.codeCoverageSummary.lineCoveragePercentage.toFixed(1)}%` : undefined]),
            { statusColumn: 1, title: `Last ${BUILD_LIMIT} reports`, emptyMessage: 'No reports' },
          ),
        ],
      }),
    ],
    tags: tags(g.tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'proj') return projectPage(c, id, rest);
  if (kind === 'rg') return reportGroupPage(c, id, rest);
  throw httpError(`Unknown CodeBuild page: ${id}`, 400);
}

/** CodeBuild has no Tag API: tags are replaced as a whole through Update*. */
async function retag(profile: string, region: string, id: string, change: (t: Tag[]) => Tag[]) {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'proj') {
    const p = await getProject(c, rest);
    await c.send(new UpdateProjectCommand({ name: rest, tags: change(p.tags || []) }));
  } else if (kind === 'rg') {
    const g = (await c.send(new BatchGetReportGroupsCommand({ reportGroupArns: [rest] }))).reportGroups?.[0];
    if (!g) throw httpError(`Report group not found: ${rest}`, 404);
    await c.send(new UpdateReportGroupCommand({ arn: rest, tags: change(g.tags || []) }));
  } else {
    throw httpError(`Unknown CodeBuild resource: ${id}`, 400);
  }
}

export const codeBuildAdapter: PageServiceAdapter = {
  list,
  detail,
  addTag: (profile, region, id, _arn, key, value) => retag(profile, region, id, (t) => [...t.filter((x) => x.key !== key), { key, value }]),
  removeTag: (profile, region, id, _arn, key) => retag(profile, region, id, (t) => t.filter((x) => x.key !== key)),
  countable: (row) => row.id.startsWith('proj:'),
};
