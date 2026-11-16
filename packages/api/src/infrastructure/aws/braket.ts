import {
  BraketClient,
  SearchDevicesCommand,
  GetDeviceCommand,
  SearchQuantumTasksCommand,
  SearchJobsCommand,
  GetJobCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-braket';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, tagMap, clientConfig, byName, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Amazon Braket: available quantum devices / simulators, recent quantum tasks and hybrid jobs. */
const client = (p: string, r: string) => new BraketClient(clientConfig(p, r));
const TASK_LIMIT = 100;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [devices, jobs] = await Promise.all([
    pageAll((nextToken) => c.send(new SearchDevicesCommand({ nextToken, filters: [] })), (r) => r.devices, (r) => r.nextToken),
    pageAll((nextToken) => c.send(new SearchJobsCommand({ nextToken, filters: [] })), (r) => r.jobs, (r) => r.nextToken, 200).catch(() => []),
  ]);
  return [
    { id: 'tasks:', name: 'Quantum tasks', group: 'Tasks', info: `Most recent ${TASK_LIMIT}` },
    ...jobs.map((j) => ({ id: `job:${j.jobArn}`, name: j.jobName || '', group: 'Hybrid jobs', status: j.status, info: lastPart(j.device) })).sort(byName),
    ...devices.map((d) => ({ id: `dev:${d.deviceArn}`, name: d.deviceName || '', group: 'Devices', status: d.deviceStatus, info: [d.providerName, d.deviceType].filter(Boolean).join(' · ') })).sort(byName),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'tasks') {
    const tasks = await pageAll((nextToken) => c.send(new SearchQuantumTasksCommand({ nextToken, filters: [] })), (r) => r.quantumTasks, (r) => r.nextToken, TASK_LIMIT);
    return {
      id,
      title: 'Quantum tasks',
      subtitle: `Most recent ${TASK_LIMIT}`,
      tabs: [tab('Tasks', { tables: [table(['Task', 'Status', 'Device', 'Shots', 'Created', 'Ended', 'Output'], tasks.sort((a, b) => (b.createdAt?.getTime() ?? 0) - (a.createdAt?.getTime() ?? 0)).slice(0, TASK_LIMIT).map((t) => [lastPart(t.quantumTaskArn), t.status, lastPart(t.deviceArn), t.shots, t.createdAt, t.endedAt, `s3://${t.outputS3Bucket}/${t.outputS3Directory}`]), { statusColumn: 1, emptyMessage: 'No quantum tasks' })] })],
      actions: [],
      errors: [],
    };
  }
  if (kind === 'dev') {
    const d = await c.send(new GetDeviceCommand({ deviceArn: arn }));
    let caps: string | undefined;
    try {
      caps = JSON.stringify(JSON.parse(String(d.deviceCapabilities)), null, 2);
    } catch {
      caps = undefined;
    }
    return {
      id,
      title: d.deviceName || arn,
      subtitle: `${d.providerName ?? ''} ${d.deviceType ?? ''}`.trim(),
      status: d.deviceStatus,
      arn,
      tabs: [
        tab('Details', {
          sections: [section('Device', [['Provider', d.providerName], ['Type', d.deviceType], ['Status', d.deviceStatus]])],
          tables: [table(['Queue', 'Priority', 'Size'], (d.deviceQueueInfo || []).map((q) => [q.queue, q.queuePriority, q.queueSize]), { title: 'Queue', emptyMessage: 'No queue information' })],
        }),
        ...(caps ? [tab('Capabilities', { json: caps })] : []),
      ],
      actions: [],
      errors: [],
    };
  }
  if (kind === 'job') {
    const j = await c.send(new GetJobCommand({ jobArn: arn }));
    return {
      id,
      title: j.jobName || arn,
      subtitle: 'Hybrid job',
      status: j.status,
      arn,
      tabs: [tab('Details', { sections: [section('Job', [['Status', j.status], ['Failure', j.failureReason], ['Device', j.deviceConfig?.device], ['Instance', j.instanceConfig && `${j.instanceConfig.instanceCount ?? 1} × ${j.instanceConfig.instanceType}`], ['Algorithm', j.algorithmSpecification?.containerImage?.uri ?? j.algorithmSpecification?.scriptModeConfig?.entryPoint], ['Output', j.outputDataConfig?.s3Path], ['Billable time (s)', j.billableDuration], ['Role', j.roleArn], ['Created', j.createdAt], ['Ended', j.endedAt]])] })],
      tags: tagMap(j.tags),
      actions: [],
      errors: [],
    };
  }
  throw httpError(`Unknown Braket page: ${id}`, 400);
}

export const braketAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !id.startsWith('job:')) throw httpError('Only hybrid jobs can be tagged here', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !id.startsWith('job:')) throw httpError('Only hybrid jobs can be tagged here', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
  uncounted: true,
};
