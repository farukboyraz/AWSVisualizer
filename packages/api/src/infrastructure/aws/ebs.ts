import {
  EC2Client,
  DescribeVolumesCommand,
  DescribeVolumeStatusCommand,
  DescribeSnapshotsCommand,
  CreateSnapshotCommand,
  CreateTagsCommand,
  DeleteTagsCommand,
  type Volume,
  type Snapshot,
  type Tag,
} from '@aws-sdk/client-ec2';
import { cachedCredentials } from './credential-cache.js';
import type { EbsVolume, EbsSnapshot, EbsVolumeDetail, EbsVolumeStatus } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): EC2Client {
  return new EC2Client({ region, credentials: cachedCredentials(profile) });
}

/** Snapshot list cap - accounts with automated backups can hold tens of thousands. */
const SNAPSHOT_LIMIT = 1000;

const tagsOf = (tags?: Tag[]) => (tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' }));
const nameOf = (tags?: Tag[]) => tags?.find((t) => t.Key === 'Name')?.Value;
const errorText = (label: string, err: unknown) => `${label}: ${err instanceof Error ? err.message : String(err)}`;

function mapVolume(v: Volume): EbsVolume {
  return {
    volumeId: v.VolumeId || '',
    name: nameOf(v.Tags),
    volumeType: v.VolumeType,
    size: v.Size,
    iops: v.Iops,
    throughput: v.Throughput,
    state: v.State,
    availabilityZone: v.AvailabilityZone,
    encrypted: v.Encrypted,
    kmsKeyId: v.KmsKeyId,
    snapshotId: v.SnapshotId || undefined,
    multiAttachEnabled: v.MultiAttachEnabled,
    createTime: v.CreateTime?.toISOString(),
    attachments: (v.Attachments || []).map((a) => ({
      instanceId: a.InstanceId,
      device: a.Device,
      state: a.State,
      attachTime: a.AttachTime?.toISOString(),
      deleteOnTermination: a.DeleteOnTermination,
    })),
    tags: tagsOf(v.Tags),
  };
}

function mapSnapshot(s: Snapshot): EbsSnapshot {
  return {
    snapshotId: s.SnapshotId || '',
    name: nameOf(s.Tags),
    description: s.Description,
    volumeId: s.VolumeId,
    volumeSize: s.VolumeSize,
    state: s.State,
    progress: s.Progress,
    startTime: s.StartTime?.toISOString(),
    encrypted: s.Encrypted,
    kmsKeyId: s.KmsKeyId,
    storageTier: s.StorageTier,
    ownerId: s.OwnerId,
    tags: tagsOf(s.Tags),
  };
}

export async function listEbsVolumes(profile: string, region: string): Promise<EbsVolume[]> {
  const client = createClient(profile, region);
  const out: EbsVolume[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new DescribeVolumesCommand({ NextToken, MaxResults: 500 }));
    out.push(...(res.Volumes || []).map(mapVolume));
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => (b.createTime || '').localeCompare(a.createTime || ''));
}

/** Snapshots this account owns, newest first, capped at SNAPSHOT_LIMIT. */
export async function listEbsSnapshots(profile: string, region: string, volumeId?: string): Promise<{ snapshots: EbsSnapshot[]; truncated: boolean }> {
  const client = createClient(profile, region);
  const out: EbsSnapshot[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(
      new DescribeSnapshotsCommand({
        OwnerIds: ['self'],
        Filters: volumeId ? [{ Name: 'volume-id', Values: [volumeId] }] : undefined,
        NextToken,
        MaxResults: 1000,
      }),
    );
    out.push(...(res.Snapshots || []).map(mapSnapshot));
    NextToken = res.NextToken;
  } while (NextToken && out.length < SNAPSHOT_LIMIT);
  out.sort((a, b) => (b.startTime || '').localeCompare(a.startTime || ''));
  return { snapshots: out.slice(0, SNAPSHOT_LIMIT), truncated: Boolean(NextToken) || out.length > SNAPSHOT_LIMIT };
}

export async function getEbsVolume(profile: string, region: string, volumeId: string): Promise<EbsVolumeDetail> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeVolumesCommand({ VolumeIds: [volumeId] }));
  const v = res.Volumes?.[0];
  if (!v) throw new Error(`Volume not found: ${volumeId}`);
  const errors: string[] = [];
  const [statusRes, snapRes] = await Promise.allSettled([
    client.send(new DescribeVolumeStatusCommand({ VolumeIds: [volumeId] })),
    listEbsSnapshots(profile, region, volumeId),
  ]);
  let status: EbsVolumeStatus | undefined;
  if (statusRes.status === 'fulfilled') {
    const s = statusRes.value.VolumeStatuses?.[0];
    if (s) {
      const detail = (name: string) => s.VolumeStatus?.Details?.find((d) => d.Name === name)?.Status;
      status = {
        status: s.VolumeStatus?.Status,
        ioEnabled: detail('io-enabled'),
        ioPerformance: detail('io-performance'),
        events: (s.Events || []).map((e) => ({
          type: e.EventType,
          description: e.Description,
          notBefore: e.NotBefore?.toISOString(),
          notAfter: e.NotAfter?.toISOString(),
        })),
        actions: (s.Actions || []).map((a) => ({ code: a.Code, description: a.Description })),
      };
    }
  } else {
    errors.push(errorText('Status checks', statusRes.reason));
  }
  let snapshots: EbsSnapshot[] = [];
  if (snapRes.status === 'fulfilled') snapshots = snapRes.value.snapshots;
  else errors.push(errorText('Snapshots', snapRes.reason));
  return { volume: mapVolume(v), status, snapshots, errors };
}

export async function createEbsSnapshot(profile: string, region: string, volumeId: string, description: string): Promise<EbsSnapshot> {
  const res = await createClient(profile, region).send(
    new CreateSnapshotCommand({ VolumeId: volumeId, Description: description || undefined }),
  );
  return mapSnapshot(res);
}

/** Volume and snapshot ids share EC2's tagging API. */
export async function addEbsTag(profile: string, region: string, resourceId: string, key: string, value: string): Promise<void> {
  await createClient(profile, region).send(new CreateTagsCommand({ Resources: [resourceId], Tags: [{ Key: key, Value: value }] }));
}

export async function removeEbsTag(profile: string, region: string, resourceId: string, key: string): Promise<void> {
  await createClient(profile, region).send(new DeleteTagsCommand({ Resources: [resourceId], Tags: [{ Key: key }] }));
}
