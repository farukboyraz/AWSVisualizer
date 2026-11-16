import {
  AppRunnerClient,
  ListServicesCommand,
  DescribeServiceCommand,
  ListOperationsCommand,
  DescribeCustomDomainsCommand,
  ListTagsForResourceCommand,
  PauseServiceCommand,
  ResumeServiceCommand,
  StartDeploymentCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-apprunner';
import { cachedCredentials } from './credential-cache.js';
import type {
  AppRunnerServiceSummary,
  AppRunnerServiceDetail,
  AppRunnerActivity,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): AppRunnerClient {
  return new AppRunnerClient({ region, credentials: cachedCredentials(profile) });
}

export async function listAppRunnerServices(profile: string, region: string): Promise<AppRunnerServiceSummary[]> {
  const client = createClient(profile, region);
  const out: AppRunnerServiceSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListServicesCommand({ NextToken, MaxResults: 20 }));
    for (const s of res.ServiceSummaryList || []) {
      out.push({
        serviceName: s.ServiceName || '',
        serviceArn: s.ServiceArn || '',
        serviceId: s.ServiceId,
        serviceUrl: s.ServiceUrl,
        status: s.Status,
        createdAt: s.CreatedAt?.toISOString(),
        updatedAt: s.UpdatedAt?.toISOString(),
      });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => a.serviceName.localeCompare(b.serviceName));
}

export async function getAppRunnerService(profile: string, region: string, arn: string): Promise<AppRunnerServiceDetail> {
  const client = createClient(profile, region);
  const [res, tagRes] = await Promise.all([
    client.send(new DescribeServiceCommand({ ServiceArn: arn })),
    client.send(new ListTagsForResourceCommand({ ResourceArn: arn })).catch(() => undefined),
  ]);
  const s = res.Service;
  if (!s) throw new Error(`Service not found: ${arn}`);
  const src = s.SourceConfiguration;
  const image = src?.ImageRepository;
  const code = src?.CodeRepository;
  const imageConfig = image?.ImageConfiguration;
  const codeValues = code?.CodeConfiguration?.CodeConfigurationValues;
  const env = imageConfig?.RuntimeEnvironmentVariables || codeValues?.RuntimeEnvironmentVariables || {};
  const secrets = imageConfig?.RuntimeEnvironmentSecrets || codeValues?.RuntimeEnvironmentSecrets || {};
  const hc = s.HealthCheckConfiguration;

  return {
    serviceName: s.ServiceName || '',
    serviceArn: s.ServiceArn || arn,
    serviceId: s.ServiceId,
    serviceUrl: s.ServiceUrl,
    status: s.Status,
    createdAt: s.CreatedAt?.toISOString(),
    updatedAt: s.UpdatedAt?.toISOString(),
    sourceType: image ? 'Container image' : code ? 'Source code repository' : undefined,
    imageIdentifier: image?.ImageIdentifier,
    imageRepositoryType: image?.ImageRepositoryType,
    repositoryUrl: code?.RepositoryUrl,
    branch: code?.SourceCodeVersion?.Value,
    autoDeploymentsEnabled: src?.AutoDeploymentsEnabled,
    port: imageConfig?.Port || codeValues?.Port,
    startCommand: imageConfig?.StartCommand || codeValues?.StartCommand,
    runtime: codeValues?.Runtime,
    buildCommand: codeValues?.BuildCommand,
    environmentVariables: Object.entries(env).map(([key, value]) => ({ key, value })),
    // Only the names - values are Secrets Manager / SSM references, never fetched.
    secretNames: Object.keys(secrets),
    cpu: s.InstanceConfiguration?.Cpu,
    memory: s.InstanceConfiguration?.Memory,
    instanceRoleArn: s.InstanceConfiguration?.InstanceRoleArn,
    healthCheck: hc
      ? `${hc.Protocol}${hc.Path ? ` ${hc.Path}` : ''} · every ${hc.Interval}s · timeout ${hc.Timeout}s · healthy ${hc.HealthyThreshold} / unhealthy ${hc.UnhealthyThreshold}`
      : undefined,
    autoScalingConfigurationName: s.AutoScalingConfigurationSummary?.AutoScalingConfigurationName,
    autoScalingConfigurationArn: s.AutoScalingConfigurationSummary?.AutoScalingConfigurationArn,
    egressType: s.NetworkConfiguration?.EgressConfiguration?.EgressType,
    vpcConnectorArn: s.NetworkConfiguration?.EgressConfiguration?.VpcConnectorArn,
    isPubliclyAccessible: s.NetworkConfiguration?.IngressConfiguration?.IsPubliclyAccessible,
    ipAddressType: s.NetworkConfiguration?.IpAddressType,
    observabilityEnabled: s.ObservabilityConfiguration?.ObservabilityEnabled,
    kmsKey: s.EncryptionConfiguration?.KmsKey,
    tags: (tagRes?.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

export async function getAppRunnerActivity(profile: string, region: string, arn: string): Promise<AppRunnerActivity> {
  const client = createClient(profile, region);
  const [ops, domains] = await Promise.all([
    client.send(new ListOperationsCommand({ ServiceArn: arn, MaxResults: 20 })),
    client.send(new DescribeCustomDomainsCommand({ ServiceArn: arn })).catch(() => undefined),
  ]);
  return {
    operations: (ops.OperationSummaryList || []).map((o) => ({
      id: o.Id || '',
      type: o.Type,
      status: o.Status,
      startedAt: o.StartedAt?.toISOString(),
      endedAt: o.EndedAt?.toISOString(),
    })),
    customDomains: (domains?.CustomDomains || []).map((d) => ({
      domainName: d.DomainName || '',
      status: d.Status,
      enableWWWSubdomain: d.EnableWWWSubdomain,
      validationRecords: (d.CertificateValidationRecords || []).map((r) => `${r.Type} ${r.Name} → ${r.Value} (${r.Status})`),
    })),
    dnsTarget: domains?.DNSTarget,
  };
}

export type AppRunnerAction = 'pause' | 'resume' | 'deploy';

export async function runAppRunnerAction(profile: string, region: string, arn: string, action: AppRunnerAction): Promise<AppRunnerServiceDetail> {
  const client = createClient(profile, region);
  if (action === 'pause') await client.send(new PauseServiceCommand({ ServiceArn: arn }));
  else if (action === 'resume') await client.send(new ResumeServiceCommand({ ServiceArn: arn }));
  else await client.send(new StartDeploymentCommand({ ServiceArn: arn }));
  return getAppRunnerService(profile, region, arn);
}

export async function addAppRunnerTag(profile: string, region: string, arn: string, key: string, value: string): Promise<AppRunnerServiceDetail> {
  await createClient(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  return getAppRunnerService(profile, region, arn);
}

export async function removeAppRunnerTag(profile: string, region: string, arn: string, key: string): Promise<AppRunnerServiceDetail> {
  await createClient(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  return getAppRunnerService(profile, region, arn);
}
