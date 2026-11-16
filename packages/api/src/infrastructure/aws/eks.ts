import {
  EKSClient,
  ListClustersCommand,
  DescribeClusterCommand,
  ListNodegroupsCommand,
  DescribeNodegroupCommand,
  ListFargateProfilesCommand,
  DescribeFargateProfileCommand,
  ListAddonsCommand,
  DescribeAddonCommand,
  ListAccessEntriesCommand,
  DescribeAccessEntryCommand,
  ListUpdatesCommand,
  DescribeUpdateCommand,
  UpdateNodegroupConfigCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Cluster,
  type Nodegroup,
  type FargateProfile,
} from '@aws-sdk/client-eks';
import { cachedCredentials } from './credential-cache.js';
import type {
  EksClusterSummary,
  EksClusterDetail,
  EksNodegroup,
  EksFargateProfile,
  EksAddon,
  EksAccessEntry,
  EksUpdate,
  EksCompute,
  ResourceTag,
} from '../../domain/entities/index.js';

export function createEksClient(profile: string, region: string): EKSClient {
  return new EKSClient({ region, credentials: cachedCredentials(profile) });
}

function tags(record?: Record<string, string>): ResourceTag[] {
  return Object.entries(record || {}).map(([key, value]) => ({ key, value })).sort((a, b) => a.key.localeCompare(b.key));
}

/** Runs `fn` over items with at most `limit` in flight (EKS Describe* throttles). */
async function mapLimited<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    })
  );
  return out;
}

async function listNames(fetchPage: (token?: string) => Promise<{ names?: string[]; next?: string }>): Promise<string[]> {
  const names: string[] = [];
  let token: string | undefined;
  do {
    const page = await fetchPage(token);
    names.push(...(page.names || []));
    token = page.next;
  } while (token);
  return names;
}

function summarize(c: Cluster): EksClusterSummary {
  return {
    name: c.name || '',
    arn: c.arn,
    status: c.status,
    version: c.version,
    platformVersion: c.platformVersion,
    createdAt: c.createdAt?.toISOString(),
  };
}

export async function listEksClusters(profile: string, region: string): Promise<EksClusterSummary[]> {
  const client = createEksClient(profile, region);
  const names = await listNames(async (nextToken) => {
    const res = await client.send(new ListClustersCommand({ nextToken }));
    return { names: res.clusters, next: res.nextToken };
  });
  const clusters = await mapLimited(names, 5, async (name) => {
    const res = await client.send(new DescribeClusterCommand({ name }));
    return res.cluster ? summarize(res.cluster) : { name };
  });
  return clusters.sort((a, b) => a.name.localeCompare(b.name));
}

export async function getEksCluster(profile: string, region: string, name: string): Promise<EksClusterDetail> {
  const client = createEksClient(profile, region);
  const res = await client.send(new DescribeClusterCommand({ name }));
  const c = res.cluster;
  if (!c) throw new Error(`Cluster not found: ${name}`);
  const vpc = c.resourcesVpcConfig;
  const logging = c.logging?.clusterLogging || [];
  return {
    ...summarize(c),
    endpoint: c.endpoint,
    roleArn: c.roleArn,
    oidcIssuer: c.identity?.oidc?.issuer,
    certificateAuthority: Boolean(c.certificateAuthority?.data),
    vpcId: vpc?.vpcId,
    subnetIds: vpc?.subnetIds || [],
    securityGroupIds: vpc?.securityGroupIds || [],
    clusterSecurityGroupId: vpc?.clusterSecurityGroupId,
    endpointPublicAccess: vpc?.endpointPublicAccess,
    endpointPrivateAccess: vpc?.endpointPrivateAccess,
    publicAccessCidrs: vpc?.publicAccessCidrs || [],
    serviceIpv4Cidr: c.kubernetesNetworkConfig?.serviceIpv4Cidr,
    ipFamily: c.kubernetesNetworkConfig?.ipFamily,
    authenticationMode: c.accessConfig?.authenticationMode,
    supportType: (c as { upgradePolicy?: { supportType?: string } }).upgradePolicy?.supportType,
    enabledLogTypes: logging.filter((l) => l.enabled).flatMap((l) => l.types || []),
    disabledLogTypes: logging.filter((l) => !l.enabled).flatMap((l) => l.types || []),
    secretsEncryptionKeyArn: c.encryptionConfig?.[0]?.provider?.keyArn,
    healthIssues: (c.health?.issues || []).map((i) => `${i.code}: ${i.message}`),
    tags: tags(c.tags),
  };
}

function mapNodegroup(n: Nodegroup): EksNodegroup {
  const lt = n.launchTemplate;
  return {
    name: n.nodegroupName || '',
    arn: n.nodegroupArn,
    status: n.status,
    capacityType: n.capacityType,
    amiType: n.amiType,
    instanceTypes: n.instanceTypes || [],
    minSize: n.scalingConfig?.minSize,
    maxSize: n.scalingConfig?.maxSize,
    desiredSize: n.scalingConfig?.desiredSize,
    version: n.version,
    releaseVersion: n.releaseVersion,
    diskSize: n.diskSize,
    nodeRole: n.nodeRole,
    subnets: n.subnets || [],
    launchTemplate: lt ? `${lt.name || lt.id}${lt.version ? ` (v${lt.version})` : ''}` : undefined,
    labels: tags(n.labels),
    taints: (n.taints || []).map((t) => `${t.key}=${t.value ?? ''}:${t.effect}`),
    healthIssues: (n.health?.issues || []).map((i) => `${i.code}: ${i.message}`),
    autoScalingGroups: (n.resources?.autoScalingGroups || []).map((g) => g.name || '').filter(Boolean),
    createdAt: n.createdAt?.toISOString(),
  };
}

export function mapFargateProfile(p: FargateProfile): EksFargateProfile {
  return {
    name: p.fargateProfileName || '',
    arn: p.fargateProfileArn,
    status: p.status,
    podExecutionRoleArn: p.podExecutionRoleArn,
    subnets: p.subnets || [],
    selectors: (p.selectors || []).map((s) => {
      const labels = Object.entries(s.labels || {}).map(([k, v]) => `${k}=${v}`).join(', ');
      return labels ? `${s.namespace} {${labels}}` : s.namespace || '*';
    }),
    createdAt: p.createdAt?.toISOString(),
  };
}

export async function listFargateProfiles(client: EKSClient, clusterName: string): Promise<EksFargateProfile[]> {
  const names = await listNames(async (nextToken) => {
    const res = await client.send(new ListFargateProfilesCommand({ clusterName, nextToken }));
    return { names: res.fargateProfileNames, next: res.nextToken };
  });
  const profiles = await mapLimited(names, 5, async (fargateProfileName) => {
    const res = await client.send(new DescribeFargateProfileCommand({ clusterName, fargateProfileName }));
    return res.fargateProfile ? mapFargateProfile(res.fargateProfile) : { name: fargateProfileName, subnets: [], selectors: [] };
  });
  return profiles.sort((a, b) => a.name.localeCompare(b.name));
}

export async function getEksCompute(profile: string, region: string, clusterName: string): Promise<EksCompute> {
  const client = createEksClient(profile, region);
  const nodegroupNames = await listNames(async (nextToken) => {
    const res = await client.send(new ListNodegroupsCommand({ clusterName, nextToken }));
    return { names: res.nodegroups, next: res.nextToken };
  });
  const [nodegroups, fargateProfiles] = await Promise.all([
    mapLimited(nodegroupNames, 5, async (nodegroupName) => {
      const res = await client.send(new DescribeNodegroupCommand({ clusterName, nodegroupName }));
      return res.nodegroup ? mapNodegroup(res.nodegroup) : ({ name: nodegroupName } as EksNodegroup);
    }),
    listFargateProfiles(client, clusterName),
  ]);
  return { nodegroups: nodegroups.sort((a, b) => a.name.localeCompare(b.name)), fargateProfiles };
}

export async function getEksAddons(profile: string, region: string, clusterName: string): Promise<EksAddon[]> {
  const client = createEksClient(profile, region);
  const names = await listNames(async (nextToken) => {
    const res = await client.send(new ListAddonsCommand({ clusterName, nextToken }));
    return { names: res.addons, next: res.nextToken };
  });
  const addons = await mapLimited(names, 5, async (addonName) => {
    const a = (await client.send(new DescribeAddonCommand({ clusterName, addonName }))).addon;
    return {
      name: addonName,
      version: a?.addonVersion,
      status: a?.status,
      serviceAccountRoleArn: a?.serviceAccountRoleArn,
      healthIssues: (a?.health?.issues || []).map((i) => `${i.code}: ${i.message}`),
      createdAt: a?.createdAt?.toISOString(),
      modifiedAt: a?.modifiedAt?.toISOString(),
    };
  });
  return addons.sort((a, b) => a.name.localeCompare(b.name));
}

/** Access entries (API / API_AND_CONFIG_MAP auth modes); CONFIG_MAP-only clusters reject the call. */
export async function getEksAccessEntries(profile: string, region: string, clusterName: string): Promise<EksAccessEntry[]> {
  const client = createEksClient(profile, region);
  const arns = await listNames(async (nextToken) => {
    const res = await client.send(new ListAccessEntriesCommand({ clusterName, nextToken }));
    return { names: res.accessEntries, next: res.nextToken };
  });
  const entries = await mapLimited(arns, 5, async (principalArn) => {
    const e = (await client.send(new DescribeAccessEntryCommand({ clusterName, principalArn }))).accessEntry;
    return {
      principalArn,
      type: e?.type,
      username: e?.username,
      kubernetesGroups: e?.kubernetesGroups || [],
      createdAt: e?.createdAt?.toISOString(),
    };
  });
  return entries.sort((a, b) => a.principalArn.localeCompare(b.principalArn));
}

/** Latest 20 cluster updates (version upgrades, config changes), newest first. */
export async function getEksUpdates(profile: string, region: string, clusterName: string): Promise<EksUpdate[]> {
  const client = createEksClient(profile, region);
  const res = await client.send(new ListUpdatesCommand({ name: clusterName, maxResults: 20 }));
  const updates = await mapLimited(res.updateIds || [], 5, async (updateId) => {
    const u = (await client.send(new DescribeUpdateCommand({ name: clusterName, updateId }))).update;
    return {
      id: updateId,
      type: u?.type,
      status: u?.status,
      createdAt: u?.createdAt?.toISOString(),
      params: (u?.params || []).map((p) => `${p.type}: ${p.value}`),
      errors: (u?.errors || []).map((e) => `${e.errorCode}: ${e.errorMessage}`),
    };
  });
  return updates.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
}

export async function updateNodegroupScaling(
  profile: string,
  region: string,
  clusterName: string,
  nodegroupName: string,
  minSize: number,
  maxSize: number,
  desiredSize: number
): Promise<EksCompute> {
  const client = createEksClient(profile, region);
  await client.send(new UpdateNodegroupConfigCommand({ clusterName, nodegroupName, scalingConfig: { minSize, maxSize, desiredSize } }));
  return getEksCompute(profile, region, clusterName);
}

export async function addEksTag(profile: string, region: string, arn: string, key: string, value: string): Promise<void> {
  await createEksClient(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
}

export async function removeEksTag(profile: string, region: string, arn: string, key: string): Promise<void> {
  await createEksClient(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
}
