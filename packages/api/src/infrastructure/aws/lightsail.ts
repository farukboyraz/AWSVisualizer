import {
  LightsailClient,
  GetInstancesCommand,
  GetInstanceCommand,
  GetInstancePortStatesCommand,
  GetInstanceSnapshotsCommand,
  GetRelationalDatabasesCommand,
  GetContainerServicesCommand,
  StartInstanceCommand,
  StopInstanceCommand,
  RebootInstanceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Instance,
  type Tag,
} from '@aws-sdk/client-lightsail';
import { cachedCredentials } from './credential-cache.js';
import type {
  LightsailInstance,
  LightsailInstanceDetail,
  LightsailDatabase,
  LightsailContainerService,
  LightsailSnapshot,
  ResourceTag,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): LightsailClient {
  return new LightsailClient({ region, credentials: cachedCredentials(profile) });
}

function mapTags(tags?: Tag[]): ResourceTag[] {
  return (tags || []).map((t) => ({ key: t.key || '', value: t.value || '' }));
}

function summarize(i: Instance): LightsailInstance {
  return {
    name: i.name || '',
    arn: i.arn || '',
    blueprintName: i.blueprintName,
    bundleId: i.bundleId,
    state: i.state?.name,
    publicIp: i.publicIpAddress,
    privateIp: i.privateIpAddress,
    isStaticIp: i.isStaticIp ?? false,
    availabilityZone: i.location?.availabilityZone,
    createdAt: i.createdAt?.toISOString(),
  };
}

export async function listLightsailInstances(profile: string, region: string): Promise<LightsailInstance[]> {
  const client = createClient(profile, region);
  const out: LightsailInstance[] = [];
  let pageToken: string | undefined;
  do {
    const res = await client.send(new GetInstancesCommand({ pageToken }));
    out.push(...(res.instances || []).map(summarize));
    pageToken = res.nextPageToken;
  } while (pageToken);
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

async function snapshotsFor(client: LightsailClient, instanceName: string): Promise<LightsailSnapshot[]> {
  const out: LightsailSnapshot[] = [];
  let pageToken: string | undefined;
  do {
    const res = await client.send(new GetInstanceSnapshotsCommand({ pageToken }));
    for (const s of res.instanceSnapshots || []) {
      if (s.fromInstanceName !== instanceName) continue;
      out.push({ name: s.name || '', state: s.state, sizeInGb: s.sizeInGb, createdAt: s.createdAt?.toISOString() });
    }
    pageToken = res.nextPageToken;
  } while (pageToken);
  return out.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
}

export async function getLightsailInstanceDetail(profile: string, region: string, name: string): Promise<LightsailInstanceDetail> {
  const client = createClient(profile, region);
  const [instRes, portRes, snapshots] = await Promise.all([
    client.send(new GetInstanceCommand({ instanceName: name })),
    client.send(new GetInstancePortStatesCommand({ instanceName: name })),
    snapshotsFor(client, name),
  ]);
  const i = instRes.instance;
  if (!i) throw new Error(`Instance not found: ${name}`);
  const autoSnapshot = i.addOns?.find((a) => a.name === 'AutoSnapshot');

  return {
    ...summarize(i),
    blueprintId: i.blueprintId,
    cpuCount: i.hardware?.cpuCount,
    ramSizeInGb: i.hardware?.ramSizeInGb,
    ipv6Addresses: i.ipv6Addresses || [],
    ipAddressType: i.ipAddressType,
    username: i.username,
    sshKeyName: i.sshKeyName,
    monthlyTransferGb: i.networking?.monthlyTransfer?.gbPerMonthAllocated,
    autoSnapshot: autoSnapshot ? `${autoSnapshot.status}${autoSnapshot.snapshotTimeOfDay ? ` · ${autoSnapshot.snapshotTimeOfDay} UTC` : ''}` : undefined,
    disks: (i.hardware?.disks || []).map((d) => ({
      name: d.name || '',
      sizeInGb: d.sizeInGb,
      path: d.path,
      isSystemDisk: d.isSystemDisk ?? false,
      iops: d.iops,
      state: d.state,
    })),
    ports: (portRes.portStates || []).map((p) => ({
      fromPort: p.fromPort,
      toPort: p.toPort,
      protocol: p.protocol,
      state: p.state,
      cidrs: [...(p.cidrs || []), ...(p.ipv6Cidrs || [])],
    })),
    snapshots,
    tags: mapTags(i.tags),
  };
}

export async function listLightsailDatabases(profile: string, region: string): Promise<LightsailDatabase[]> {
  const client = createClient(profile, region);
  const out: LightsailDatabase[] = [];
  let pageToken: string | undefined;
  do {
    const res = await client.send(new GetRelationalDatabasesCommand({ pageToken }));
    for (const d of res.relationalDatabases || []) {
      const endpoint = d.masterEndpoint?.address ? `${d.masterEndpoint.address}:${d.masterEndpoint.port ?? ''}` : undefined;
      out.push({
        name: d.name || '',
        arn: d.arn || '',
        engine: d.engine,
        engineVersion: d.engineVersion,
        state: d.state,
        masterUsername: d.masterUsername,
        masterDatabaseName: d.masterDatabaseName,
        endpoint,
        bundleId: d.relationalDatabaseBundleId,
        availabilityZone: d.location?.availabilityZone,
        backupRetentionEnabled: d.backupRetentionEnabled ?? false,
        publiclyAccessible: d.publiclyAccessible ?? false,
        preferredBackupWindow: d.preferredBackupWindow,
        preferredMaintenanceWindow: d.preferredMaintenanceWindow,
        createdAt: d.createdAt?.toISOString(),
        tags: mapTags(d.tags),
      });
    }
    pageToken = res.nextPageToken;
  } while (pageToken);
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

export async function listLightsailContainerServices(profile: string, region: string): Promise<LightsailContainerService[]> {
  const client = createClient(profile, region);
  const res = await client.send(new GetContainerServicesCommand({}));
  return (res.containerServices || [])
    .map((s) => ({
      name: s.containerServiceName || '',
      arn: s.arn || '',
      state: s.state,
      power: s.power,
      scale: s.scale,
      url: s.url,
      isDisabled: s.isDisabled ?? false,
      privateDomainName: s.privateDomainName,
      containers: Object.entries(s.currentDeployment?.containers || {}).map(([name, c]) => `${name}: ${c.image || ''}`),
      createdAt: s.createdAt?.toISOString(),
      tags: mapTags(s.tags),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

export type LightsailInstanceAction = 'start' | 'stop' | 'reboot';

export async function runLightsailInstanceAction(
  profile: string,
  region: string,
  name: string,
  action: LightsailInstanceAction
): Promise<LightsailInstanceDetail> {
  const client = createClient(profile, region);
  if (action === 'start') await client.send(new StartInstanceCommand({ instanceName: name }));
  else if (action === 'stop') await client.send(new StopInstanceCommand({ instanceName: name }));
  else await client.send(new RebootInstanceCommand({ instanceName: name }));
  return getLightsailInstanceDetail(profile, region, name);
}

/** Lightsail tags by resource *name* (instance, database, container service). */
export async function addLightsailTag(profile: string, region: string, resourceName: string, key: string, value: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ resourceName, tags: [{ key, value }] }));
}

export async function removeLightsailTag(profile: string, region: string, resourceName: string, key: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ resourceName, tagKeys: [key] }));
}
