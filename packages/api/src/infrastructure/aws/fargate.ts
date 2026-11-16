import { ECSClient, ListClustersCommand, ListTasksCommand, DescribeTasksCommand } from '@aws-sdk/client-ecs';
import { cachedCredentials } from './credential-cache.js';
import { mapEcsTask } from './ecs.js';
import { createEksClient, listEksClusters, listFargateProfiles } from './eks.js';
import type { FargateOverview, FargateTask } from '../../domain/entities/index.js';

/**
 * Fargate has no API of its own: it's ECS tasks launched on Fargate plus
 * EKS Fargate profiles. This walks every ECS cluster for running Fargate
 * tasks (capped per cluster) and every EKS cluster for its profiles.
 */

const TASKS_PER_CLUSTER = 200;

function errorMessage(err: unknown): string {
  return (err as Error)?.message || String(err);
}

async function listFargateTasks(profile: string, region: string): Promise<{ tasks: FargateTask[]; truncated: boolean }> {
  const client = new ECSClient({ region, credentials: cachedCredentials(profile) });
  const clusterArns: string[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new ListClustersCommand({ nextToken }));
    clusterArns.push(...(res.clusterArns || []));
    nextToken = res.nextToken;
  } while (nextToken);

  let truncated = false;
  const perCluster = await Promise.all(
    clusterArns.map(async (cluster) => {
      const arns: string[] = [];
      let token: string | undefined;
      do {
        const res = await client.send(new ListTasksCommand({ cluster, launchType: 'FARGATE', desiredStatus: 'RUNNING', nextToken: token, maxResults: 100 }));
        arns.push(...(res.taskArns || []));
        token = res.nextToken;
      } while (token && arns.length < TASKS_PER_CLUSTER);
      if (token) truncated = true;
      if (arns.length === 0) return [];
      const pages = await Promise.all(
        Array.from({ length: Math.ceil(arns.length / 100) }, (_, i) =>
          client.send(new DescribeTasksCommand({ cluster, tasks: arns.slice(i * 100, i * 100 + 100) }))
        )
      );
      const clusterName = cluster.split('/').pop() || cluster;
      return pages.flatMap((p) => p.tasks || []).map((t) => ({
        ...mapEcsTask(t),
        clusterName,
        clusterArn: cluster,
        group: t.group,
        capacityProviderName: t.capacityProviderName,
        platformVersion: t.platformVersion,
      }));
    })
  );
  const tasks = perCluster.flat().sort((a, b) => a.clusterName.localeCompare(b.clusterName) || (b.startedAt || '').localeCompare(a.startedAt || ''));
  return { tasks, truncated };
}

async function listAllFargateProfiles(profile: string, region: string): Promise<FargateOverview['profiles']> {
  const clusters = await listEksClusters(profile, region);
  const client = createEksClient(profile, region);
  const perCluster = await Promise.all(
    clusters.map(async (c) => (await listFargateProfiles(client, c.name)).map((p) => ({ ...p, clusterName: c.name })))
  );
  return perCluster.flat();
}

export async function getFargateOverview(profile: string, region: string): Promise<FargateOverview> {
  const [taskResult, profileResult] = await Promise.allSettled([
    listFargateTasks(profile, region),
    listAllFargateProfiles(profile, region),
  ]);
  const errors: string[] = [];
  if (taskResult.status === 'rejected') errors.push(`ECS: ${errorMessage(taskResult.reason)}`);
  if (profileResult.status === 'rejected') errors.push(`EKS: ${errorMessage(profileResult.reason)}`);
  if (errors.length === 2) throw taskResult.status === 'rejected' ? taskResult.reason : new Error(errors.join('; '));
  return {
    tasks: taskResult.status === 'fulfilled' ? taskResult.value.tasks : [],
    truncated: taskResult.status === 'fulfilled' ? taskResult.value.truncated : false,
    profiles: profileResult.status === 'fulfilled' ? profileResult.value : [],
    errors,
  };
}

/** For the sidebar count: running Fargate tasks + EKS Fargate profiles. */
export async function listFargateItems(profile: string, region: string): Promise<unknown[]> {
  const o = await getFargateOverview(profile, region);
  return [...o.tasks, ...o.profiles];
}
