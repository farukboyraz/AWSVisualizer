import {
  Macie2Client,
  GetMacieSessionCommand,
  GetBucketStatisticsCommand,
  DescribeBucketsCommand,
  ListClassificationJobsCommand,
  DescribeClassificationJobCommand,
  ListFindingsCommand,
  GetFindingsCommand,
  GetFindingStatisticsCommand,
  GetAutomatedDiscoveryConfigurationCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-macie2';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, isNotEnabled } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new Macie2Client({ region: r, credentials: cachedCredentials(p) });

const FINDING_LIMIT = 50;
const BUCKET_LIMIT = 500;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  let session;
  try {
    session = await c.send(new GetMacieSessionCommand({}));
  } catch (err) {
    // "Macie is not enabled" comes back as AccessDenied.
    if (isNotEnabled(err)) return [];
    throw err;
  }
  const jobs = await pageAll((nextToken) => c.send(new ListClassificationJobsCommand({ nextToken, maxResults: 200 })), (r) => r.items, (r) => r.nextToken).catch(() => []);
  return [
    { id: 'session:', name: 'Summary', status: session.status, info: `Findings published every ${session.findingPublishingFrequency ?? '-'}` },
    { id: 'buckets:', name: 'S3 buckets', info: 'Inventory, public access and sensitivity' },
    ...jobs
      .map((j) => ({ id: `job:${j.jobId}`, name: j.name || j.jobId || '', group: 'Jobs', status: j.jobStatus, info: [j.jobType, j.createdAt && `created ${j.createdAt.toISOString().slice(0, 10)}`].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function sessionPage(c: Macie2Client, id: string): Promise<ResourcePage> {
  const s = await c.send(new GetMacieSessionCommand({}));
  const errors: string[] = [];
  const parts = await settle(
    {
      stats: c.send(new GetBucketStatisticsCommand({})),
      severity: c.send(new GetFindingStatisticsCommand({ groupBy: 'severity.description' })),
      discovery: c.send(new GetAutomatedDiscoveryConfigurationCommand({})),
      ids: c.send(new ListFindingsCommand({ maxResults: FINDING_LIMIT, sortCriteria: { attributeName: 'updatedAt', orderBy: 'DESC' } })),
    },
    errors,
  );
  const findings = parts.ids?.findingIds?.length ? await c.send(new GetFindingsCommand({ findingIds: parts.ids.findingIds })).then((r) => r.findings || []).catch((err) => (errors.push(`Findings: ${err.message}`), [])) : [];
  const st = parts.stats;
  const perm = st?.bucketCountByEffectivePermission;
  const enc = st?.bucketCountByEncryptionType;
  return {
    id,
    title: 'Amazon Macie',
    subtitle: 'Summary',
    status: s.status,
    tabs: [
      tab('Summary', {
        sections: [
          section('Settings', [
            ['Status', s.status],
            ['Finding publishing frequency', s.findingPublishingFrequency],
            ['Automated sensitive data discovery', parts.discovery?.status],
            ['Service role', s.serviceRole],
            ['Enabled', s.createdAt],
            ['Updated', s.updatedAt],
          ]),
          section('S3 buckets', [
            ['Buckets', st?.bucketCount],
            ['Classifiable objects', st?.classifiableObjectCount],
            ['Classifiable size (bytes)', st?.classifiableSizeInBytes],
            ['Publicly accessible', perm?.publiclyAccessible],
            ['Publicly writable', perm?.publiclyWritable],
            ['Publicly readable', perm?.publiclyReadable],
            ['Shared outside the account', st?.bucketCountBySharedAccessType?.external],
            ['Encrypted by default (SSE-S3 / SSE-KMS)', enc ? `${enc.s3Managed ?? 0} / ${enc.kmsManaged ?? 0}` : undefined],
            ['No default encryption', enc?.unencrypted],
          ]),
        ],
        tables: [table(['Severity', 'Findings'], (parts.severity?.countsByGroup || []).map((g) => [g.groupKey, g.count]), { title: 'Findings by severity', emptyMessage: 'No findings' })],
      }),
      tab('Findings', {
        tables: [
          table(
            ['Severity', 'Type', 'Title', 'Bucket', 'Object', 'Count', 'Updated'],
            findings.map((f) => [f.severity?.description, f.type, f.title, f.resourcesAffected?.s3Bucket?.name, f.resourcesAffected?.s3Object?.key, f.count, f.updatedAt]),
            { title: `Latest ${FINDING_LIMIT} findings`, statusColumn: 0, emptyMessage: 'No findings' },
          ),
        ],
      }),
    ],
    actions: [],
    errors,
  };
}

async function bucketsPage(c: Macie2Client, id: string): Promise<ResourcePage> {
  const buckets = await pageAll((nextToken) => c.send(new DescribeBucketsCommand({ nextToken, maxResults: 50 })), (r) => r.buckets, (r) => r.nextToken, BUCKET_LIMIT);
  return {
    id,
    title: 'S3 buckets',
    subtitle: buckets.length >= BUCKET_LIMIT ? `First ${BUCKET_LIMIT} buckets` : `${buckets.length} buckets`,
    tabs: [
      tab('Buckets', {
        tables: [
          table(
            ['Bucket', 'Account', 'Region', 'Public access', 'Default encryption', 'Shared access', 'Sensitivity score', 'Classifiable objects', 'Last discovery'],
            buckets.map((b) => [b.bucketName, b.accountId, b.region, b.publicAccess?.effectivePermission, b.serverSideEncryption?.type, b.sharedAccess, b.sensitivityScore, b.classifiableObjectCount, b.lastAutomatedDiscoveryTime]),
            { emptyMessage: 'No buckets' },
          ),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function jobPage(c: Macie2Client, id: string, jobId: string): Promise<ResourcePage> {
  const j = await c.send(new DescribeClassificationJobCommand({ jobId }));
  const def = j.s3JobDefinition;
  const sched = j.scheduleFrequency;
  return {
    id,
    title: j.name || jobId,
    subtitle: j.description || `${j.jobType ?? ''} job`,
    status: j.jobStatus,
    arn: j.jobArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Job', [
            ['Job ID', j.jobId],
            ['Type', j.jobType],
            ['Status', j.jobStatus],
            ['Schedule', sched?.dailySchedule ? 'Daily' : sched?.weeklySchedule ? `Weekly (${sched.weeklySchedule.dayOfWeek})` : sched?.monthlySchedule ? `Monthly (day ${sched.monthlySchedule.dayOfMonth})` : j.jobType === 'ONE_TIME' ? 'One time' : undefined],
            ['Sampling', j.samplingPercentage !== undefined ? `${j.samplingPercentage}%` : undefined],
            ['Managed data identifiers', j.managedDataIdentifierSelector],
            ['Custom data identifiers', j.customDataIdentifierIds],
            ['Allow lists', j.allowListIds],
            ['Created', j.createdAt],
            ['Last run', j.lastRunTime],
            ['Last run errors', j.lastRunErrorStatus?.code],
          ]),
          section('Statistics', [
            ['Approximate objects to process', j.statistics?.approximateNumberOfObjectsToProcess],
            ['Number of runs', j.statistics?.numberOfRuns],
          ]),
        ],
        tables: [
          table(
            ['Account', 'Buckets'],
            (def?.bucketDefinitions || []).map((b) => [b.accountId, b.buckets]),
            { title: def?.bucketCriteria ? 'Buckets (selected by criteria - see JSON)' : 'Buckets', emptyMessage: def?.bucketCriteria ? 'Buckets are selected by criteria' : 'No buckets' },
          ),
        ],
      }),
      tab('Scope (JSON)', { json: JSON.stringify({ bucketCriteria: def?.bucketCriteria, scoping: def?.scoping }, null, 2) }),
    ],
    tags: tagMap(j.tags),
    actions: [],
    errors: [],
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'session') return sessionPage(c, id);
  if (kind === 'buckets') return bucketsPage(c, id);
  if (kind === 'job') return jobPage(c, id, rest);
  throw httpError(`Unknown Macie page: ${id}`, 400);
}

export const macieAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (!id.startsWith('job:')) throw httpError('Only jobs can be tagged here', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!id.startsWith('job:')) throw httpError('Only jobs can be tagged here', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('job:'),
};
