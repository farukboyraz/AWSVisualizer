import {
  ElasticBeanstalkClient,
  DescribeEnvironmentsCommand,
  DescribeEventsCommand,
  DescribeConfigurationSettingsCommand,
  ListTagsForResourceCommand,
  RestartAppServerCommand,
  RebuildEnvironmentCommand,
  TerminateEnvironmentCommand,
  SwapEnvironmentCNAMEsCommand,
  UpdateEnvironmentCommand,
  UpdateTagsForResourceCommand,
  CreateEnvironmentCommand,
  DescribeEnvironmentHealthCommand,
  DescribeInstancesHealthCommand,
  DescribeEnvironmentResourcesCommand,
  DescribeApplicationVersionsCommand,
  RequestEnvironmentInfoCommand,
  RetrieveEnvironmentInfoCommand,
  DescribeEnvironmentManagedActionsCommand,
  DescribeEnvironmentManagedActionHistoryCommand,
  ApplyEnvironmentManagedActionCommand,
  type EnvironmentDescription,
  type ApplicationMetrics,
} from '@aws-sdk/client-elastic-beanstalk';
import { cachedCredentials } from './credential-cache.js';
import type {
  Environment,
  EbEvent,
  EbEnvironmentDetail,
  EbEnvironmentHealth,
  EbEnvironmentResources,
  EbConfiguration,
  EbApplicationVersion,
  EbLogEntry,
  EbManagedUpdates,
  EbLatency,
  EbStatusCodes,
} from '../../domain/entities/index.js';

function createEbClient(profile: string, region: string): ElasticBeanstalkClient {
  return new ElasticBeanstalkClient({
    region,
    credentials: cachedCredentials(profile),
  });
}

export async function getEnvironments(profile: string, region: string): Promise<Environment[]> {
  const client = createEbClient(profile, region);

  const all: EnvironmentDescription[] = [];
  let NextToken: string | undefined;
  do {
    const response = await client.send(new DescribeEnvironmentsCommand({ IncludeDeleted: false, NextToken, MaxRecords: 1000 }));
    all.push(...(response.Environments || []));
    NextToken = response.NextToken;
  } while (NextToken);

  return all.map((env) => ({
    environmentName: env.EnvironmentName || '',
    environmentId: env.EnvironmentId || '',
    applicationName: env.ApplicationName || '',
    status: env.Status || '',
    health: env.Health || '',
    healthStatus: env.HealthStatus,
    solutionStackName: env.SolutionStackName,
    platformArn: env.PlatformArn,
    versionLabel: env.VersionLabel,
    dateCreated: env.DateCreated?.toISOString(),
    dateUpdated: env.DateUpdated?.toISOString(),
    endpointURL: env.EndpointURL,
    cname: env.CNAME,
    tier: env.Tier
      ? {
          name: env.Tier.Name || '',
          type: env.Tier.Type || '',
        }
      : undefined,
  }));
}

export async function getEvents(
  profile: string,
  region: string,
  envName: string,
  maxItems?: number
): Promise<EbEvent[]> {
  const client = createEbClient(profile, region);

  const command = new DescribeEventsCommand({
    EnvironmentName: envName,
    MaxRecords: maxItems || 50,
  });

  const response = await client.send(command);

  return (response.Events || []).map((event) => ({
    eventDate: event.EventDate?.toISOString() || '',
    message: event.Message || '',
    applicationName: event.ApplicationName || '',
    environmentName: event.EnvironmentName,
    severity: event.Severity || '',
  }));
}

async function fetchEnvironment(client: ElasticBeanstalkClient, environmentName: string): Promise<EnvironmentDescription> {
  const response = await client.send(new DescribeEnvironmentsCommand({ EnvironmentNames: [environmentName], IncludeDeleted: false }));
  const env = response.Environments?.[0];
  if (!env) {
    throw new Error(`Environment not found: ${environmentName}`);
  }
  return env;
}

const ENV_VAR_NAMESPACE = 'aws:elasticbeanstalk:application:environment';

export async function getEnvironmentDetail(profile: string, region: string, environmentName: string): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  const env = await fetchEnvironment(client, environmentName);

  const [configRes, tagsRes] = await Promise.all([
    client
      .send(new DescribeConfigurationSettingsCommand({ ApplicationName: env.ApplicationName || '', EnvironmentName: environmentName }))
      .catch(() => undefined),
    env.EnvironmentArn
      ? client.send(new ListTagsForResourceCommand({ ResourceArn: env.EnvironmentArn })).catch(() => undefined)
      : undefined,
  ]);

  const optionSettings = configRes?.ConfigurationSettings?.[0]?.OptionSettings || [];
  const environmentVariables = optionSettings
    .filter((o) => o.Namespace === ENV_VAR_NAMESPACE && o.OptionName)
    .map((o) => ({ key: o.OptionName || '', value: o.Value || '' }));

  const tags = (tagsRes?.ResourceTags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' }));

  return {
    environmentName: env.EnvironmentName || environmentName,
    environmentId: env.EnvironmentId || '',
    environmentArn: env.EnvironmentArn,
    applicationName: env.ApplicationName || '',
    status: env.Status || '',
    health: env.Health || '',
    healthStatus: env.HealthStatus,
    solutionStackName: env.SolutionStackName,
    platformArn: env.PlatformArn,
    versionLabel: env.VersionLabel,
    dateCreated: env.DateCreated?.toISOString(),
    dateUpdated: env.DateUpdated?.toISOString(),
    endpointURL: env.EndpointURL,
    cname: env.CNAME,
    tier: env.Tier ? { name: env.Tier.Name || '', type: env.Tier.Type || '' } : undefined,
    environmentVariables,
    tags,
  };
}

export async function restartAppServer(profile: string, region: string, environmentName: string): Promise<void> {
  const client = createEbClient(profile, region);
  await client.send(new RestartAppServerCommand({ EnvironmentName: environmentName }));
}

export async function rebuildEnvironment(profile: string, region: string, environmentName: string): Promise<void> {
  const client = createEbClient(profile, region);
  await client.send(new RebuildEnvironmentCommand({ EnvironmentName: environmentName }));
}

export async function terminateEnvironment(profile: string, region: string, environmentName: string): Promise<void> {
  const client = createEbClient(profile, region);
  await client.send(new TerminateEnvironmentCommand({ EnvironmentName: environmentName }));
}

export async function swapEnvironmentCnames(
  profile: string,
  region: string,
  sourceEnvironmentName: string,
  destinationEnvironmentName: string
): Promise<void> {
  const client = createEbClient(profile, region);
  await client.send(
    new SwapEnvironmentCNAMEsCommand({ SourceEnvironmentName: sourceEnvironmentName, DestinationEnvironmentName: destinationEnvironmentName })
  );
}

export async function setEnvironmentVariable(
  profile: string,
  region: string,
  environmentName: string,
  key: string,
  value: string
): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  await client.send(
    new UpdateEnvironmentCommand({
      EnvironmentName: environmentName,
      OptionSettings: [{ Namespace: ENV_VAR_NAMESPACE, OptionName: key, Value: value }],
    })
  );
  return getEnvironmentDetail(profile, region, environmentName);
}

export async function removeEnvironmentVariable(profile: string, region: string, environmentName: string, key: string): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  await client.send(
    new UpdateEnvironmentCommand({
      EnvironmentName: environmentName,
      OptionsToRemove: [{ Namespace: ENV_VAR_NAMESPACE, OptionName: key }],
    })
  );
  return getEnvironmentDetail(profile, region, environmentName);
}

export async function addEnvironmentTag(
  profile: string,
  region: string,
  environmentName: string,
  environmentArn: string,
  key: string,
  value: string
): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  await client.send(new UpdateTagsForResourceCommand({ ResourceArn: environmentArn, TagsToAdd: [{ Key: key, Value: value }] }));
  return getEnvironmentDetail(profile, region, environmentName);
}

export async function removeEnvironmentTag(
  profile: string,
  region: string,
  environmentName: string,
  environmentArn: string,
  key: string
): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  await client.send(new UpdateTagsForResourceCommand({ ResourceArn: environmentArn, TagsToRemove: [key] }));
  return getEnvironmentDetail(profile, region, environmentName);
}

export interface CloneEnvironmentParams {
  sourceEnvironmentName: string;
  newEnvironmentName: string;
  cnamePrefix?: string;
}

// Approximates the console's "Clone Environment" action: reuses the source
// environment's platform, app version and tier. It doesn't replicate every
// configuration option (instance types, scaling rules, env vars, etc.) -
// a byte-for-byte clone needs DescribeConfigurationSettings' full option
// list fed back into CreateEnvironment, which is a lot of surface area for
// a "minimal but real" launch flow (same scope call as EC2's Launch
// Instance).
export async function cloneEnvironment(profile: string, region: string, params: CloneEnvironmentParams): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  const source = await fetchEnvironment(client, params.sourceEnvironmentName);

  await client.send(
    new CreateEnvironmentCommand({
      ApplicationName: source.ApplicationName || '',
      EnvironmentName: params.newEnvironmentName,
      CNAMEPrefix: params.cnamePrefix || undefined,
      VersionLabel: source.VersionLabel,
      PlatformArn: source.PlatformArn,
      SolutionStackName: source.PlatformArn ? undefined : source.SolutionStackName,
      Tier: source.Tier,
    })
  );
  return getEnvironmentDetail(profile, region, params.newEnvironmentName);
}

// ---- Health, resources, configuration, versions, logs, managed updates ----

function latency(m?: ApplicationMetrics): EbLatency | undefined {
  const l = m?.Latency;
  if (!l) return undefined;
  return { p999: l.P999, p99: l.P99, p95: l.P95, p90: l.P90, p75: l.P75, p50: l.P50, p10: l.P10 };
}

function statusCodes(m?: ApplicationMetrics): EbStatusCodes | undefined {
  const c = m?.StatusCodes;
  if (!c) return undefined;
  return { status2xx: c.Status2xx, status3xx: c.Status3xx, status4xx: c.Status4xx, status5xx: c.Status5xx };
}

/**
 * Enhanced health (DescribeEnvironmentHealth + DescribeInstancesHealth).
 * Environments on basic health reject those calls; then only the
 * environment's color and its instance ids are reported.
 */
export async function getEnvironmentHealth(profile: string, region: string, environmentName: string): Promise<EbEnvironmentHealth> {
  const client = createEbClient(profile, region);
  try {
    const [envHealth, instHealth] = await Promise.all([
      client.send(new DescribeEnvironmentHealthCommand({ EnvironmentName: environmentName, AttributeNames: ['All'] })),
      collectInstancesHealth(client, environmentName),
    ]);
    const m = envHealth.ApplicationMetrics;
    const counts = envHealth.InstancesHealth;
    return {
      enhanced: true,
      color: envHealth.Color,
      healthStatus: envHealth.HealthStatus,
      status: envHealth.Status,
      causes: envHealth.Causes || [],
      refreshedAt: envHealth.RefreshedAt?.toISOString(),
      requestCount: m?.RequestCount,
      durationSeconds: m?.Duration,
      statusCodes: statusCodes(m),
      latency: latency(m),
      instanceCounts: counts
        ? {
            ok: counts.Ok,
            info: counts.Info,
            warning: counts.Warning,
            degraded: counts.Degraded,
            severe: counts.Severe,
            pending: counts.Pending,
            unknown: counts.Unknown,
            noData: counts.NoData,
          }
        : undefined,
      instances: instHealth,
    };
  } catch (err) {
    const { name = '', message = '' } = (err as { name?: string; message?: string }) || {};
    const basicHealth = name === 'InvalidRequestException' || /enhanced/i.test(message);
    if (!basicHealth) throw err;
    const [env, resources] = await Promise.all([
      fetchEnvironment(client, environmentName),
      client.send(new DescribeEnvironmentResourcesCommand({ EnvironmentName: environmentName })),
    ]);
    return {
      enhanced: false,
      color: env.Health,
      healthStatus: env.HealthStatus,
      status: env.Status,
      causes: [],
      instances: (resources.EnvironmentResources?.Instances || []).map((i) => ({ instanceId: i.Id || '', causes: [] })),
    };
  }
}

async function collectInstancesHealth(client: ElasticBeanstalkClient, environmentName: string) {
  const out: EbEnvironmentHealth['instances'] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new DescribeInstancesHealthCommand({ EnvironmentName: environmentName, AttributeNames: ['All'], NextToken }));
    for (const i of res.InstanceHealthList || []) {
      const cpu = i.System?.CPUUtilization;
      out.push({
        instanceId: i.InstanceId || '',
        healthStatus: i.HealthStatus,
        color: i.Color,
        causes: i.Causes || [],
        launchedAt: i.LaunchedAt?.toISOString(),
        availabilityZone: i.AvailabilityZone,
        instanceType: i.InstanceType,
        deploymentVersion: i.Deployment?.VersionLabel,
        deploymentStatus: i.Deployment?.Status,
        requestCount: i.ApplicationMetrics?.RequestCount,
        latencyP90: i.ApplicationMetrics?.Latency?.P90,
        cpuUser: cpu?.User,
        cpuIdle: cpu?.Idle,
        loadAverage1: i.System?.LoadAverage?.[0],
      });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => a.instanceId.localeCompare(b.instanceId));
}

export async function getEnvironmentResources(profile: string, region: string, environmentName: string): Promise<EbEnvironmentResources> {
  const client = createEbClient(profile, region);
  const res = await client.send(new DescribeEnvironmentResourcesCommand({ EnvironmentName: environmentName }));
  const r = res.EnvironmentResources;
  return {
    instances: (r?.Instances || []).map((i) => i.Id || '').filter(Boolean),
    autoScalingGroups: (r?.AutoScalingGroups || []).map((g) => g.Name || '').filter(Boolean),
    loadBalancers: (r?.LoadBalancers || []).map((l) => l.Name || '').filter(Boolean),
    launchTemplates: (r?.LaunchTemplates || []).map((l) => l.Id || '').filter(Boolean),
    launchConfigurations: (r?.LaunchConfigurations || []).map((l) => l.Name || '').filter(Boolean),
    queues: (r?.Queues || []).map((q) => ({ name: q.Name || '', url: q.URL })),
    triggers: (r?.Triggers || []).map((t) => t.Name || '').filter(Boolean),
  };
}

/** Every configuration option except env vars (they have their own tab). */
export async function getEnvironmentConfiguration(profile: string, region: string, environmentName: string): Promise<EbConfiguration> {
  const client = createEbClient(profile, region);
  const env = await fetchEnvironment(client, environmentName);
  const res = await client.send(new DescribeConfigurationSettingsCommand({ ApplicationName: env.ApplicationName || '', EnvironmentName: environmentName }));
  const settings = res.ConfigurationSettings?.[0];
  return {
    platformArn: settings?.PlatformArn,
    solutionStackName: settings?.SolutionStackName,
    deploymentStatus: settings?.DeploymentStatus,
    dateUpdated: settings?.DateUpdated?.toISOString(),
    options: (settings?.OptionSettings || [])
      .filter((o) => o.Namespace !== ENV_VAR_NAMESPACE)
      .map((o) => ({ namespace: o.Namespace || '', optionName: o.OptionName || '', value: o.Value, resourceName: o.ResourceName }))
      .sort((a, b) => a.namespace.localeCompare(b.namespace) || a.optionName.localeCompare(b.optionName)),
  };
}

/** The application's versions, newest first, with the environments running each. */
export async function listApplicationVersions(profile: string, region: string, applicationName: string): Promise<EbApplicationVersion[]> {
  const client = createEbClient(profile, region);
  const versions: EbApplicationVersion[] = [];
  let NextToken: string | undefined;
  const [, environments] = await Promise.all([
    (async () => {
      do {
        const res = await client.send(new DescribeApplicationVersionsCommand({ ApplicationName: applicationName, NextToken, MaxRecords: 100 }));
        for (const v of res.ApplicationVersions || []) {
          const bundle = v.SourceBundle;
          const repo = v.SourceBuildInformation;
          versions.push({
            versionLabel: v.VersionLabel || '',
            description: v.Description,
            status: v.Status,
            dateCreated: v.DateCreated?.toISOString(),
            dateUpdated: v.DateUpdated?.toISOString(),
            sourceBundle: bundle?.S3Bucket ? `s3://${bundle.S3Bucket}/${bundle.S3Key || ''}` : undefined,
            sourceRepository: repo ? `${repo.SourceRepository} ${repo.SourceLocation}` : undefined,
            deployedTo: [],
          });
        }
        NextToken = res.NextToken;
      } while (NextToken && versions.length < 500);
    })(),
    getEnvironments(profile, region),
  ]);
  for (const env of environments) {
    if (env.applicationName !== applicationName || !env.versionLabel) continue;
    versions.find((v) => v.versionLabel === env.versionLabel)?.deployedTo.push(env.environmentName);
  }
  return versions.sort((a, b) => (b.dateCreated || '').localeCompare(a.dateCreated || ''));
}

/** The console's "Deploy" on an application version. */
export async function deployApplicationVersion(profile: string, region: string, environmentName: string, versionLabel: string): Promise<EbEnvironmentDetail> {
  const client = createEbClient(profile, region);
  await client.send(new UpdateEnvironmentCommand({ EnvironmentName: environmentName, VersionLabel: versionLabel }));
  return getEnvironmentDetail(profile, region, environmentName);
}

const TAIL_LIMIT = 512 * 1024;

async function fetchText(url: string): Promise<{ content?: string; truncated?: boolean }> {
  try {
    const host = new URL(url).hostname;
    if (!host.endsWith('.amazonaws.com')) return {};
    const res = await fetch(url);
    if (!res.ok) return {};
    const text = await res.text();
    return text.length > TAIL_LIMIT ? { content: text.slice(-TAIL_LIMIT), truncated: true } : { content: text };
  } catch {
    return {};
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * "Request logs": asks every instance for its last 100 lines (tail) or a
 * full bundle, then polls until the new samples arrive (usually 5-20 s).
 * Tail text is downloaded here; bundles come back as presigned S3 URLs.
 */
export async function fetchEnvironmentLogs(
  profile: string,
  region: string,
  environmentName: string,
  infoType: 'tail' | 'bundle'
): Promise<EbLogEntry[]> {
  const client = createEbClient(profile, region);
  const requestedAt = Date.now() - 2000;
  await client.send(new RequestEnvironmentInfoCommand({ EnvironmentName: environmentName, InfoType: infoType }));

  let fresh: { Ec2InstanceId?: string; SampleTimestamp?: Date; Message?: string }[] = [];
  for (let attempt = 0; attempt < 20; attempt++) {
    await sleep(3000);
    const res = await client.send(new RetrieveEnvironmentInfoCommand({ EnvironmentName: environmentName, InfoType: infoType }));
    fresh = (res.EnvironmentInfo || []).filter((i) => (i.SampleTimestamp?.getTime() || 0) >= requestedAt && i.Message);
    if (fresh.length > 0) {
      // Give slower instances one more round to report.
      await sleep(3000);
      const again = await client.send(new RetrieveEnvironmentInfoCommand({ EnvironmentName: environmentName, InfoType: infoType }));
      fresh = (again.EnvironmentInfo || []).filter((i) => (i.SampleTimestamp?.getTime() || 0) >= requestedAt && i.Message);
      break;
    }
  }

  const latest = new Map<string, (typeof fresh)[number]>();
  for (const item of fresh) {
    const id = item.Ec2InstanceId || '';
    const prev = latest.get(id);
    if (!prev || (item.SampleTimestamp?.getTime() || 0) > (prev.SampleTimestamp?.getTime() || 0)) latest.set(id, item);
  }

  return Promise.all(
    [...latest.values()].map(async (item) => ({
      instanceId: item.Ec2InstanceId || '',
      sampleTimestamp: item.SampleTimestamp?.toISOString(),
      url: item.Message || '',
      ...(infoType === 'tail' ? await fetchText(item.Message || '') : {}),
    }))
  ).then((entries) => entries.sort((a, b) => a.instanceId.localeCompare(b.instanceId)));
}

export async function getManagedUpdates(profile: string, region: string, environmentName: string): Promise<EbManagedUpdates> {
  const client = createEbClient(profile, region);
  const [pendingRes, historyRes] = await Promise.all([
    client.send(new DescribeEnvironmentManagedActionsCommand({ EnvironmentName: environmentName })),
    client.send(new DescribeEnvironmentManagedActionHistoryCommand({ EnvironmentName: environmentName, MaxItems: 25 })),
  ]);
  return {
    pending: (pendingRes.ManagedActions || []).map((a) => ({
      actionId: a.ActionId || '',
      actionType: a.ActionType,
      actionDescription: a.ActionDescription,
      status: a.Status,
      windowStartTime: a.WindowStartTime?.toISOString(),
    })),
    history: (historyRes.ManagedActionHistoryItems || []).map((h) => ({
      actionId: h.ActionId || '',
      actionType: h.ActionType,
      actionDescription: h.ActionDescription,
      status: h.Status,
      failureType: h.FailureType,
      failureDescription: h.FailureDescription,
      executedTime: h.ExecutedTime?.toISOString(),
      finishedTime: h.FinishedTime?.toISOString(),
    })),
  };
}

/** "Apply now" on a scheduled platform update instead of waiting for the window. */
export async function applyManagedAction(profile: string, region: string, environmentName: string, actionId: string): Promise<EbManagedUpdates> {
  const client = createEbClient(profile, region);
  await client.send(new ApplyEnvironmentManagedActionCommand({ EnvironmentName: environmentName, ActionId: actionId }));
  return getManagedUpdates(profile, region, environmentName);
}
