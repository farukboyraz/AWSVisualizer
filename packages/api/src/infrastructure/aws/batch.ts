import {
  BatchClient,
  DescribeJobQueuesCommand,
  DescribeComputeEnvironmentsCommand,
  DescribeJobDefinitionsCommand,
  ListJobsCommand,
  DescribeJobsCommand,
  UpdateJobQueueCommand,
  UpdateComputeEnvironmentCommand,
  TerminateJobCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type JobQueueDetail,
  type ComputeEnvironmentDetail,
  type JobDefinition,
  type JobStatus,
} from '@aws-sdk/client-batch';
import { cachedCredentials } from './credential-cache.js';
import type {
  BatchJobQueue,
  BatchComputeEnvironment,
  BatchJobDefinition,
  BatchOverview,
  BatchJobSummary,
  BatchJobDetail,
  ResourceTag,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): BatchClient {
  return new BatchClient({ region, credentials: cachedCredentials(profile) });
}

export const BATCH_JOB_STATUSES = ['SUBMITTED', 'PENDING', 'RUNNABLE', 'STARTING', 'RUNNING', 'SUCCEEDED', 'FAILED'] as const;

function recordToTags(record?: Record<string, string>): ResourceTag[] {
  return Object.entries(record || {})
    .map(([key, value]) => ({ key, value }))
    .sort((a, b) => a.key.localeCompare(b.key));
}

/** "arn:aws:batch:...:compute-environment/name" -> "name". */
function arnName(arn?: string): string {
  if (!arn) return '';
  return arn.split('/').pop() || arn;
}

function iso(epochMs?: number): string | undefined {
  return epochMs ? new Date(epochMs).toISOString() : undefined;
}

function resourceRequirement(
  reqs: { type?: string; value?: string }[] | undefined,
  type: string,
  legacy?: number
): string | undefined {
  const found = reqs?.find((r) => r.type === type)?.value;
  if (found) return found;
  return legacy !== undefined ? String(legacy) : undefined;
}

function mapQueue(q: JobQueueDetail): BatchJobQueue {
  return {
    jobQueueName: q.jobQueueName || '',
    jobQueueArn: q.jobQueueArn || '',
    state: q.state,
    status: q.status,
    statusReason: q.statusReason,
    priority: q.priority,
    computeEnvironments: [...(q.computeEnvironmentOrder || [])]
      .sort((a, b) => (a.order ?? 0) - (b.order ?? 0))
      .map((c) => arnName(c.computeEnvironment)),
    schedulingPolicyArn: q.schedulingPolicyArn,
    tags: recordToTags(q.tags),
  };
}

function mapComputeEnvironment(c: ComputeEnvironmentDetail): BatchComputeEnvironment {
  const r = c.computeResources;
  const lt = r?.launchTemplate;
  return {
    computeEnvironmentName: c.computeEnvironmentName || '',
    computeEnvironmentArn: c.computeEnvironmentArn || '',
    type: c.type,
    state: c.state,
    status: c.status,
    statusReason: c.statusReason,
    resourceType: r?.type,
    minvCpus: r?.minvCpus,
    maxvCpus: r?.maxvCpus,
    desiredvCpus: r?.desiredvCpus,
    instanceTypes: r?.instanceTypes || [],
    allocationStrategy: r?.allocationStrategy,
    subnets: r?.subnets || [],
    securityGroupIds: r?.securityGroupIds || [],
    instanceRole: r?.instanceRole,
    launchTemplate: lt ? `${lt.launchTemplateName || lt.launchTemplateId}${lt.version ? ` (${lt.version})` : ''}` : undefined,
    serviceRole: c.serviceRole,
    ecsClusterArn: c.ecsClusterArn,
    eksClusterArn: c.eksConfiguration?.eksClusterArn,
    tags: recordToTags(c.tags),
  };
}

function mapJobDefinition(d: JobDefinition): BatchJobDefinition {
  const container = d.containerProperties;
  const props = d.containerProperties || d.nodeProperties || d.eksProperties || d.ecsProperties;
  return {
    jobDefinitionName: d.jobDefinitionName || '',
    jobDefinitionArn: d.jobDefinitionArn || '',
    revision: d.revision ?? 0,
    type: d.type,
    status: d.status,
    platformCapabilities: d.platformCapabilities || [],
    image: container?.image,
    vcpus: resourceRequirement(container?.resourceRequirements, 'VCPU', container?.vcpus),
    memory: resourceRequirement(container?.resourceRequirements, 'MEMORY', container?.memory),
    timeoutSeconds: d.timeout?.attemptDurationSeconds,
    retryAttempts: d.retryStrategy?.attempts,
    propagateTags: d.propagateTags,
    propertiesJson: props ? JSON.stringify(props, null, 2) : undefined,
    parameters: recordToTags(d.parameters),
    tags: recordToTags(d.tags),
  };
}

async function listQueues(client: BatchClient): Promise<BatchJobQueue[]> {
  const out: BatchJobQueue[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new DescribeJobQueuesCommand({ nextToken }));
    out.push(...(res.jobQueues || []).map(mapQueue));
    nextToken = res.nextToken;
  } while (nextToken);
  return out.sort((a, b) => a.jobQueueName.localeCompare(b.jobQueueName));
}

async function listComputeEnvironments(client: BatchClient): Promise<BatchComputeEnvironment[]> {
  const out: BatchComputeEnvironment[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new DescribeComputeEnvironmentsCommand({ nextToken }));
    out.push(...(res.computeEnvironments || []).map(mapComputeEnvironment));
    nextToken = res.nextToken;
  } while (nextToken);
  return out.sort((a, b) => a.computeEnvironmentName.localeCompare(b.computeEnvironmentName));
}

/** Active revisions only, newest revision first within a name. */
async function listJobDefinitions(client: BatchClient): Promise<BatchJobDefinition[]> {
  const out: BatchJobDefinition[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new DescribeJobDefinitionsCommand({ status: 'ACTIVE', nextToken }));
    out.push(...(res.jobDefinitions || []).map(mapJobDefinition));
    nextToken = res.nextToken;
  } while (nextToken);
  return out.sort((a, b) => a.jobDefinitionName.localeCompare(b.jobDefinitionName) || b.revision - a.revision);
}

export async function listBatchJobQueues(profile: string, region: string): Promise<BatchJobQueue[]> {
  return listQueues(createClient(profile, region));
}

export async function getBatchOverview(profile: string, region: string): Promise<BatchOverview> {
  const client = createClient(profile, region);
  const [jobQueues, computeEnvironments, jobDefinitions] = await Promise.all([
    listQueues(client),
    listComputeEnvironments(client),
    listJobDefinitions(client),
  ]);
  return { jobQueues, computeEnvironments, jobDefinitions };
}

export async function getJobQueue(profile: string, region: string, name: string): Promise<BatchJobQueue> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeJobQueuesCommand({ jobQueues: [name] }));
  const q = res.jobQueues?.[0];
  if (!q) throw new Error(`Job queue not found: ${name}`);
  return mapQueue(q);
}

export async function getComputeEnvironment(profile: string, region: string, name: string): Promise<BatchComputeEnvironment> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeComputeEnvironmentsCommand({ computeEnvironments: [name] }));
  const c = res.computeEnvironments?.[0];
  if (!c) throw new Error(`Compute environment not found: ${name}`);
  return mapComputeEnvironment(c);
}

export async function getJobDefinition(profile: string, region: string, arn: string): Promise<BatchJobDefinition> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeJobDefinitionsCommand({ jobDefinitions: [arn] }));
  const d = res.jobDefinitions?.[0];
  if (!d) throw new Error(`Job definition not found: ${arn}`);
  return mapJobDefinition(d);
}

/** One status at a time, like the console's Jobs filter; newest first. */
export async function listJobs(profile: string, region: string, queue: string, status: string): Promise<BatchJobSummary[]> {
  const client = createClient(profile, region);
  const jobs: BatchJobSummary[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new ListJobsCommand({ jobQueue: queue, jobStatus: status as JobStatus, nextToken, maxResults: 100 }));
    for (const j of res.jobSummaryList || []) {
      jobs.push({
        jobId: j.jobId || '',
        jobName: j.jobName || '',
        status: j.status,
        statusReason: j.statusReason,
        createdAt: iso(j.createdAt),
        startedAt: iso(j.startedAt),
        stoppedAt: iso(j.stoppedAt),
        exitCode: j.container?.exitCode,
        jobDefinition: arnName(j.jobDefinition),
        arraySize: j.arrayProperties?.size,
      });
    }
    nextToken = res.nextToken;
  } while (nextToken && jobs.length < 500);
  return jobs.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
}

export async function getJob(profile: string, region: string, jobId: string): Promise<BatchJobDetail> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeJobsCommand({ jobs: [jobId] }));
  const j = res.jobs?.[0];
  if (!j) throw new Error(`Job not found: ${jobId}`);
  const c = j.container;
  return {
    jobId: j.jobId || jobId,
    jobName: j.jobName || '',
    jobArn: j.jobArn,
    jobQueue: arnName(j.jobQueue),
    status: j.status,
    statusReason: j.statusReason,
    createdAt: iso(j.createdAt),
    startedAt: iso(j.startedAt),
    stoppedAt: iso(j.stoppedAt),
    exitCode: c?.exitCode,
    jobDefinition: arnName(j.jobDefinition),
    arraySize: j.arrayProperties?.size,
    attempts: j.attempts?.length || 0,
    image: c?.image,
    command: c?.command || [],
    vcpus: resourceRequirement(c?.resourceRequirements, 'VCPU', c?.vcpus),
    memory: resourceRequirement(c?.resourceRequirements, 'MEMORY', c?.memory),
    logStreamName: c?.logStreamName,
    reason: c?.reason,
    dependsOn: (j.dependsOn || []).map((d) => d.jobId || '').filter(Boolean),
    environment: (c?.environment || []).map((e) => ({ key: e.name || '', value: e.value || '' })),
    tags: recordToTags(j.tags),
  };
}

export async function setJobQueueState(profile: string, region: string, name: string, enabled: boolean): Promise<BatchJobQueue> {
  const client = createClient(profile, region);
  await client.send(new UpdateJobQueueCommand({ jobQueue: name, state: enabled ? 'ENABLED' : 'DISABLED' }));
  return getJobQueue(profile, region, name);
}

export async function setComputeEnvironmentState(profile: string, region: string, name: string, enabled: boolean): Promise<BatchComputeEnvironment> {
  const client = createClient(profile, region);
  await client.send(new UpdateComputeEnvironmentCommand({ computeEnvironment: name, state: enabled ? 'ENABLED' : 'DISABLED' }));
  return getComputeEnvironment(profile, region, name);
}

/** TerminateJob also cancels jobs that haven't started yet. */
export async function terminateJob(profile: string, region: string, jobId: string, reason: string): Promise<BatchJobDetail> {
  const client = createClient(profile, region);
  await client.send(new TerminateJobCommand({ jobId, reason }));
  return getJob(profile, region, jobId);
}

export async function addBatchTag(profile: string, region: string, arn: string, key: string, value: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
}

export async function removeBatchTag(profile: string, region: string, arn: string, key: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
}
