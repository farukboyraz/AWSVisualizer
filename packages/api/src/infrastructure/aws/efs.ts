import {
  EFSClient,
  DescribeFileSystemsCommand,
  DescribeMountTargetsCommand,
  DescribeMountTargetSecurityGroupsCommand,
  DescribeAccessPointsCommand,
  DescribeReplicationConfigurationsCommand,
  DescribeFileSystemPolicyCommand,
  DescribeLifecycleConfigurationCommand,
  DescribeBackupPolicyCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type FileSystemDescription,
} from '@aws-sdk/client-efs';
import { cachedCredentials } from './credential-cache.js';
import type {
  EfsFileSystemSummary,
  EfsFileSystemDetail,
  EfsFileSystemExtras,
  EfsMountTarget,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): EFSClient {
  return new EFSClient({ region, credentials: cachedCredentials(profile) });
}

const errorText = (label: string, err: unknown) => `${label}: ${err instanceof Error ? err.message : String(err)}`;
const isNotFound = (err: unknown) => /NotFound|PolicyNotFound|ReplicationNotFound/i.test((err as { name?: string })?.name || '');

function mapSummary(fs: FileSystemDescription): EfsFileSystemSummary {
  return {
    fileSystemId: fs.FileSystemId || '',
    name: fs.Name,
    lifeCycleState: fs.LifeCycleState,
    sizeInBytes: fs.SizeInBytes?.Value,
    performanceMode: fs.PerformanceMode,
    throughputMode: fs.ThroughputMode,
    encrypted: fs.Encrypted,
    numberOfMountTargets: fs.NumberOfMountTargets,
    availabilityZoneName: fs.AvailabilityZoneName,
    creationTime: fs.CreationTime?.toISOString(),
  };
}

export async function listEfsFileSystems(profile: string, region: string): Promise<EfsFileSystemSummary[]> {
  const client = createClient(profile, region);
  const out: EfsFileSystemSummary[] = [];
  let Marker: string | undefined;
  do {
    const res = await client.send(new DescribeFileSystemsCommand({ Marker }));
    out.push(...(res.FileSystems || []).map(mapSummary));
    Marker = res.NextMarker;
  } while (Marker);
  return out.sort((a, b) => (a.name || a.fileSystemId).localeCompare(b.name || b.fileSystemId));
}

export async function getEfsFileSystem(profile: string, region: string, id: string): Promise<EfsFileSystemDetail> {
  const client = createClient(profile, region);
  const [res, lifecycle, backup] = await Promise.all([
    client.send(new DescribeFileSystemsCommand({ FileSystemId: id })),
    client.send(new DescribeLifecycleConfigurationCommand({ FileSystemId: id })).catch(() => undefined),
    client.send(new DescribeBackupPolicyCommand({ FileSystemId: id })).catch(() => undefined),
  ]);
  const fs = res.FileSystems?.[0];
  if (!fs) throw new Error(`File system not found: ${id}`);
  const lifecyclePolicies: string[] = [];
  for (const p of lifecycle?.LifecyclePolicies || []) {
    if (p.TransitionToIA) lifecyclePolicies.push(`Transition into Infrequent Access: ${p.TransitionToIA}`);
    if (p.TransitionToArchive) lifecyclePolicies.push(`Transition into Archive: ${p.TransitionToArchive}`);
    if (p.TransitionToPrimaryStorageClass) lifecyclePolicies.push(`Transition into Standard: ${p.TransitionToPrimaryStorageClass}`);
  }
  return {
    ...mapSummary(fs),
    fileSystemArn: fs.FileSystemArn,
    ownerId: fs.OwnerId,
    creationToken: fs.CreationToken,
    kmsKeyId: fs.KmsKeyId,
    provisionedThroughputInMibps: fs.ProvisionedThroughputInMibps,
    sizeInStandard: fs.SizeInBytes?.ValueInStandard,
    sizeInIA: fs.SizeInBytes?.ValueInIA,
    sizeInArchive: fs.SizeInBytes?.ValueInArchive,
    sizeTimestamp: fs.SizeInBytes?.Timestamp?.toISOString(),
    replicationOverwriteProtection: fs.FileSystemProtection?.ReplicationOverwriteProtection,
    automaticBackups: backup?.BackupPolicy?.Status,
    lifecyclePolicies,
    dnsName: `${id}.efs.${region}.amazonaws.com`,
    tags: (fs.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

/** Network, Access points, Replication and File system policy tabs - each part may fail on its own. */
export async function getEfsFileSystemExtras(profile: string, region: string, id: string): Promise<EfsFileSystemExtras> {
  const client = createClient(profile, region);
  const errors: string[] = [];

  const mountTargets = async (): Promise<EfsMountTarget[]> => {
    const res = await client.send(new DescribeMountTargetsCommand({ FileSystemId: id }));
    return Promise.all(
      (res.MountTargets || []).map(async (m) => {
        const sg = await client
          .send(new DescribeMountTargetSecurityGroupsCommand({ MountTargetId: m.MountTargetId }))
          .catch(() => undefined);
        return {
          mountTargetId: m.MountTargetId || '',
          subnetId: m.SubnetId,
          vpcId: m.VpcId,
          availabilityZoneName: m.AvailabilityZoneName,
          ipAddress: m.IpAddress,
          networkInterfaceId: m.NetworkInterfaceId,
          lifeCycleState: m.LifeCycleState,
          securityGroups: sg?.SecurityGroups || [],
        };
      }),
    );
  };

  const accessPoints = async () => {
    const out: EfsFileSystemExtras['accessPoints'] = [];
    let NextToken: string | undefined;
    do {
      const res = await client.send(new DescribeAccessPointsCommand({ FileSystemId: id, NextToken }));
      for (const a of res.AccessPoints || []) {
        const ci = a.RootDirectory?.CreationInfo;
        out.push({
          accessPointId: a.AccessPointId || '',
          accessPointArn: a.AccessPointArn,
          name: a.Name,
          lifeCycleState: a.LifeCycleState,
          path: a.RootDirectory?.Path,
          posixUser: a.PosixUser
            ? `${a.PosixUser.Uid}:${a.PosixUser.Gid}${a.PosixUser.SecondaryGids?.length ? ` (+${a.PosixUser.SecondaryGids.join(',')})` : ''}`
            : undefined,
          creationInfo: ci ? `owner ${ci.OwnerUid}:${ci.OwnerGid}, mode ${ci.Permissions}` : undefined,
        });
      }
      NextToken = res.NextToken;
    } while (NextToken);
    return out;
  };

  const replications = async () => {
    try {
      const res = await client.send(new DescribeReplicationConfigurationsCommand({ FileSystemId: id }));
      return (res.Replications || []).map((r) => ({
        sourceFileSystemId: r.SourceFileSystemId,
        sourceRegion: r.SourceFileSystemRegion,
        isSource: r.SourceFileSystemId === id,
        creationTime: r.CreationTime?.toISOString(),
        destinations: (r.Destinations || []).map((d) => ({
          fileSystemId: d.FileSystemId,
          region: d.Region,
          status: d.Status,
          lastReplicatedTimestamp: d.LastReplicatedTimestamp?.toISOString(),
        })),
      }));
    } catch (err) {
      if (isNotFound(err)) return [];
      throw err;
    }
  };

  const policy = async () => {
    try {
      return (await client.send(new DescribeFileSystemPolicyCommand({ FileSystemId: id }))).Policy;
    } catch (err) {
      if (isNotFound(err)) return undefined;
      throw err;
    }
  };

  const [mt, ap, rep, pol] = await Promise.allSettled([mountTargets(), accessPoints(), replications(), policy()]);
  const pick = <T>(r: PromiseSettledResult<T>, label: string, fallback: T): T => {
    if (r.status === 'fulfilled') return r.value;
    errors.push(errorText(label, r.reason));
    return fallback;
  };
  return {
    mountTargets: pick(mt, 'Mount targets', []),
    accessPoints: pick(ap, 'Access points', []),
    replications: pick(rep, 'Replication', []),
    policy: pick(pol, 'File system policy', undefined),
    errors,
  };
}

export async function addEfsTag(profile: string, region: string, id: string, key: string, value: string): Promise<EfsFileSystemDetail> {
  await createClient(profile, region).send(new TagResourceCommand({ ResourceId: id, Tags: [{ Key: key, Value: value }] }));
  return getEfsFileSystem(profile, region, id);
}

export async function removeEfsTag(profile: string, region: string, id: string, key: string): Promise<EfsFileSystemDetail> {
  await createClient(profile, region).send(new UntagResourceCommand({ ResourceId: id, TagKeys: [key] }));
  return getEfsFileSystem(profile, region, id);
}
