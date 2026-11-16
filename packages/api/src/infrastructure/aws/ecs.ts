import {
  ECSClient,
  ListClustersCommand,
  ListServicesCommand,
  DescribeServicesCommand,
  DescribeClustersCommand,
  ListTasksCommand,
  DescribeTasksCommand,
  DescribeTaskDefinitionCommand,
  UpdateServiceCommand,
  StopTaskCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Service,
  type DesiredStatus,
  type Task as SdkTask,
} from '@aws-sdk/client-ecs';
import { cachedCredentials } from './credential-cache.js';
import type {
  EcsCluster,
  EcsServiceSummary,
  EcsServiceDetail,
  EcsTask,
  EcsTaskDefinitionSummary,
} from '../../domain/entities/index.js';

function createEcsClient(profile: string, region: string): ECSClient {
  return new ECSClient({ region, credentials: cachedCredentials(profile) });
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export async function listClusters(profile: string, region: string): Promise<EcsCluster[]> {
  const client = createEcsClient(profile, region);
  const listCmd = new ListClustersCommand({});
  const listRes = await client.send(listCmd);
  const arns = listRes.clusterArns || [];
  if (arns.length === 0) return [];

  const descCmd = new DescribeClustersCommand({ clusters: arns });
  const descRes = await client.send(descCmd);

  return (descRes.clusters || []).map((c) => ({
    clusterName: c.clusterName || '',
    clusterArn: c.clusterArn || '',
    status: c.status || '',
    runningTasks: c.runningTasksCount || 0,
    pendingTasks: c.pendingTasksCount || 0,
    activeServices: c.activeServicesCount || 0,
    registeredContainerInstances: c.registeredContainerInstancesCount || 0,
  }));
}

function toServiceSummary(s: Service): EcsServiceSummary {
  return {
    serviceName: s.serviceName || '',
    serviceArn: s.serviceArn || '',
    status: s.status || '',
    desiredCount: s.desiredCount || 0,
    runningCount: s.runningCount || 0,
    pendingCount: s.pendingCount || 0,
    launchType: s.launchType || s.capacityProviderStrategy?.map((c) => c.capacityProvider).join(', '),
    taskDefinition: s.taskDefinition || '',
  };
}

/**
 * ListServices pages at 10 by default and DescribeServices accepts at most
 * 10 services per call - both limits are walked here, otherwise a cluster
 * with more than 10 services silently showed only the first page.
 */
export async function listServices(profile: string, region: string, cluster: string): Promise<EcsServiceSummary[]> {
  const client = createEcsClient(profile, region);
  const arns: string[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new ListServicesCommand({ cluster, nextToken, maxResults: 100 }));
    arns.push(...(res.serviceArns || []));
    nextToken = res.nextToken;
  } while (nextToken);
  if (arns.length === 0) return [];

  const pages = await Promise.all(
    chunk(arns, 10).map((services) => client.send(new DescribeServicesCommand({ cluster, services })))
  );
  return pages
    .flatMap((p) => p.services || [])
    .map(toServiceSummary)
    .sort((a, b) => a.serviceName.localeCompare(b.serviceName));
}

export async function getServiceDetail(profile: string, region: string, cluster: string, service: string): Promise<EcsServiceDetail> {
  const client = createEcsClient(profile, region);
  const res = await client.send(new DescribeServicesCommand({ cluster, services: [service], include: ['TAGS'] }));
  const s = res.services?.[0];
  if (!s) {
    const reason = res.failures?.[0]?.reason || 'Service not found';
    throw Object.assign(new Error(reason), { name: 'ServiceNotFoundException', $metadata: { httpStatusCode: 404 } });
  }
  const awsvpc = s.networkConfiguration?.awsvpcConfiguration;

  return {
    ...toServiceSummary(s),
    clusterArn: s.clusterArn || '',
    platformVersion: s.platformVersion,
    schedulingStrategy: s.schedulingStrategy,
    createdAt: s.createdAt?.toISOString(),
    createdBy: s.createdBy,
    minimumHealthyPercent: s.deploymentConfiguration?.minimumHealthyPercent,
    maximumPercent: s.deploymentConfiguration?.maximumPercent,
    circuitBreakerEnabled: s.deploymentConfiguration?.deploymentCircuitBreaker?.enable,
    circuitBreakerRollback: s.deploymentConfiguration?.deploymentCircuitBreaker?.rollback,
    subnets: awsvpc?.subnets || [],
    securityGroups: awsvpc?.securityGroups || [],
    assignPublicIp: awsvpc?.assignPublicIp,
    loadBalancers: (s.loadBalancers || []).map((lb) => ({
      targetGroupArn: lb.targetGroupArn,
      loadBalancerName: lb.loadBalancerName,
      containerName: lb.containerName,
      containerPort: lb.containerPort,
    })),
    capacityProviders: (s.capacityProviderStrategy || []).map(
      (c) => `${c.capacityProvider}${c.weight !== undefined ? ` (weight ${c.weight}, base ${c.base ?? 0})` : ''}`
    ),
    deployments: (s.deployments || []).map((d) => ({
      id: d.id || '',
      status: d.status || '',
      taskDefinition: d.taskDefinition || '',
      desiredCount: d.desiredCount || 0,
      runningCount: d.runningCount || 0,
      pendingCount: d.pendingCount || 0,
      failedTasks: d.failedTasks || 0,
      rolloutState: d.rolloutState,
      rolloutStateReason: d.rolloutStateReason,
      createdAt: d.createdAt?.toISOString(),
      updatedAt: d.updatedAt?.toISOString(),
    })),
    // ECS keeps the last 100 events; the console's Health tab shows them
    // newest first, which is already the API's order.
    events: (s.events || []).map((e) => ({
      id: e.id || '',
      createdAt: e.createdAt?.toISOString(),
      message: e.message || '',
    })),
    tags: (s.tags || []).map((t) => ({ key: t.key || '', value: t.value || '' })),
  };
}

export async function listServiceTasks(
  profile: string,
  region: string,
  cluster: string,
  service: string,
  desiredStatus: DesiredStatus
): Promise<EcsTask[]> {
  const client = createEcsClient(profile, region);
  const arns: string[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new ListTasksCommand({ cluster, serviceName: service, desiredStatus, nextToken, maxResults: 100 }));
    arns.push(...(res.taskArns || []));
    nextToken = res.nextToken;
    // Stopped tasks linger for about an hour and can pile up during a
    // crash loop - cap the walk so one service can't produce an unbounded
    // response (the same "bound the work per request" rule as CodeCommit).
  } while (nextToken && arns.length < 200);
  if (arns.length === 0) return [];

  const pages = await Promise.all(
    chunk(arns, 100).map((tasks) => client.send(new DescribeTasksCommand({ cluster, tasks })))
  );

  return pages
    .flatMap((p) => p.tasks || [])
    .map(mapEcsTask)
    .sort((a, b) => (b.startedAt || '').localeCompare(a.startedAt || ''));
}

/** DescribeTasks entry -> EcsTask (shared with the Fargate screen). */
export function mapEcsTask(t: SdkTask): EcsTask {
  const eni = t.attachments?.find((a) => a.type === 'ElasticNetworkInterface');
  const privateIp = eni?.details?.find((d) => d.name === 'privateIPv4Address')?.value;
  return {
    taskArn: t.taskArn || '',
    taskId: t.taskArn?.split('/').pop() || '',
    lastStatus: t.lastStatus,
    desiredStatus: t.desiredStatus,
    healthStatus: t.healthStatus,
    launchType: t.launchType,
    cpu: t.cpu,
    memory: t.memory,
    taskDefinition: t.taskDefinitionArn?.split('/').pop(),
    availabilityZone: t.availabilityZone,
    privateIp,
    startedAt: t.startedAt?.toISOString(),
    stoppedAt: t.stoppedAt?.toISOString(),
    stoppedReason: t.stoppedReason,
    containers: (t.containers || []).map((c) => ({
      name: c.name || '',
      image: c.image,
      lastStatus: c.lastStatus,
      healthStatus: c.healthStatus,
      exitCode: c.exitCode,
      reason: c.reason,
    })),
  };
}

export async function getTaskDefinition(profile: string, region: string, taskDefinition: string): Promise<EcsTaskDefinitionSummary> {
  const client = createEcsClient(profile, region);
  const res = await client.send(new DescribeTaskDefinitionCommand({ taskDefinition }));
  const td = res.taskDefinition;
  if (!td) throw new Error('Task definition not found');

  return {
    taskDefinitionArn: td.taskDefinitionArn || '',
    family: td.family || '',
    revision: td.revision || 0,
    cpu: td.cpu,
    memory: td.memory,
    networkMode: td.networkMode,
    requiresCompatibilities: td.requiresCompatibilities || [],
    taskRoleArn: td.taskRoleArn,
    executionRoleArn: td.executionRoleArn,
    registeredAt: td.registeredAt?.toISOString(),
    containers: (td.containerDefinitions || []).map((c) => ({
      name: c.name || '',
      image: c.image,
      cpu: c.cpu,
      memory: c.memory,
      memoryReservation: c.memoryReservation,
      essential: c.essential,
      portMappings: (c.portMappings || []).map(
        (p) => `${p.hostPort ?? p.containerPort ?? '?'}:${p.containerPort ?? '?'}/${p.protocol || 'tcp'}`
      ),
      // Only counts - values can hold credentials and the console hides
      // secrets too; the full definition is one click away in the console.
      environmentCount: c.environment?.length || 0,
      secretsCount: c.secrets?.length || 0,
      logGroup: c.logConfiguration?.options?.['awslogs-group'],
    })),
  };
}

export async function updateDesiredCount(profile: string, region: string, cluster: string, service: string, desiredCount: number): Promise<EcsServiceDetail> {
  const client = createEcsClient(profile, region);
  await client.send(new UpdateServiceCommand({ cluster, service, desiredCount }));
  return getServiceDetail(profile, region, cluster, service);
}

/** The console's "Update service → Force new deployment" - same task definition, fresh tasks. */
export async function forceNewDeployment(profile: string, region: string, cluster: string, service: string): Promise<EcsServiceDetail> {
  const client = createEcsClient(profile, region);
  await client.send(new UpdateServiceCommand({ cluster, service, forceNewDeployment: true }));
  return getServiceDetail(profile, region, cluster, service);
}

export async function stopTask(profile: string, region: string, cluster: string, task: string, reason?: string): Promise<void> {
  const client = createEcsClient(profile, region);
  await client.send(new StopTaskCommand({ cluster, task, reason: reason || 'Stopped from AWS Visualizer' }));
}

export async function addServiceTag(profile: string, region: string, cluster: string, service: string, serviceArn: string, key: string, value: string): Promise<EcsServiceDetail> {
  const client = createEcsClient(profile, region);
  await client.send(new TagResourceCommand({ resourceArn: serviceArn, tags: [{ key, value }] }));
  return getServiceDetail(profile, region, cluster, service);
}

export async function removeServiceTag(profile: string, region: string, cluster: string, service: string, serviceArn: string, key: string): Promise<EcsServiceDetail> {
  const client = createEcsClient(profile, region);
  await client.send(new UntagResourceCommand({ resourceArn: serviceArn, tagKeys: [key] }));
  return getServiceDetail(profile, region, cluster, service);
}
