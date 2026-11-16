import {
  StorageGatewayClient,
  ListGatewaysCommand,
  DescribeGatewayInformationCommand,
  DescribeMaintenanceStartTimeCommand,
  DescribeBandwidthRateLimitCommand,
  DescribeCacheCommand,
  ListVolumesCommand,
  ListFileSharesCommand,
  DescribeNFSFileSharesCommand,
  DescribeSMBFileSharesCommand,
  ListTapesCommand,
  DescribeTapesCommand,
  ListLocalDisksCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
} from '@aws-sdk/client-storage-gateway';
import { cachedCredentials } from './credential-cache.js';
import type { GatewaySummary, GatewayDetail, GatewayStorage, StorageSetting } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): StorageGatewayClient {
  return new StorageGatewayClient({ region, credentials: cachedCredentials(profile) });
}

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const errorText = (label: string, err: unknown) => `${label}: ${err instanceof Error ? err.message : String(err)}`;
/** Calls a gateway type doesn't support (cache on a volume-stored gateway, tapes on S3 File) answer InvalidGatewayRequestException. */
const unsupported = (err: unknown) => (err as { name?: string })?.name === 'InvalidGatewayRequestException';
const mbps = (bits?: number) => (bits === undefined ? 'Unlimited' : `${(bits / 1_000_000).toFixed(1)} Mbit/s`);

export async function listStorageGateways(profile: string, region: string): Promise<GatewaySummary[]> {
  const client = createClient(profile, region);
  const out: GatewaySummary[] = [];
  let Marker: string | undefined;
  do {
    const res = await client.send(new ListGatewaysCommand({ Marker }));
    for (const g of res.Gateways || []) {
      out.push({
        gatewayArn: g.GatewayARN || '',
        gatewayId: g.GatewayId,
        gatewayName: g.GatewayName,
        gatewayType: g.GatewayType,
        operationalState: g.GatewayOperationalState,
        hostEnvironment: g.HostEnvironment,
        ec2InstanceId: g.Ec2InstanceId,
        softwareVersion: g.SoftwareVersion,
      });
    }
    Marker = res.Marker;
  } while (Marker);
  return out.sort((a, b) => (a.gatewayName || '').localeCompare(b.gatewayName || ''));
}

export async function getStorageGateway(profile: string, region: string, arn: string): Promise<GatewayDetail> {
  const client = createClient(profile, region);
  const info = await client.send(new DescribeGatewayInformationCommand({ GatewayARN: arn }));
  const errors: string[] = [];
  const [maint, bw, cache] = await Promise.allSettled([
    client.send(new DescribeMaintenanceStartTimeCommand({ GatewayARN: arn })),
    client.send(new DescribeBandwidthRateLimitCommand({ GatewayARN: arn })),
    client.send(new DescribeCacheCommand({ GatewayARN: arn })),
  ]);

  let maintenance: string | undefined;
  if (maint.status === 'fulfilled') {
    const m = maint.value;
    const when = m.DayOfMonth !== undefined ? `Day ${m.DayOfMonth} of the month` : m.DayOfWeek !== undefined ? `Every ${DAYS[m.DayOfWeek] ?? m.DayOfWeek}` : 'Daily';
    const time = `${String(m.HourOfDay ?? 0).padStart(2, '0')}:${String(m.MinuteOfHour ?? 0).padStart(2, '0')}`;
    maintenance = `${when} at ${time} (${m.Timezone || info.GatewayTimezone || 'gateway time'})`;
  } else if (!unsupported(maint.reason)) errors.push(errorText('Maintenance window', maint.reason));

  let bandwidth: StorageSetting[] = [];
  if (bw.status === 'fulfilled') {
    bandwidth = [
      { label: 'Upload rate limit', value: mbps(bw.value.AverageUploadRateLimitInBitsPerSec) },
      { label: 'Download rate limit', value: mbps(bw.value.AverageDownloadRateLimitInBitsPerSec) },
    ];
  } else if (!unsupported(bw.reason)) errors.push(errorText('Bandwidth', bw.reason));

  let cacheSettings: StorageSetting[] = [];
  if (cache.status === 'fulfilled') {
    const c = cache.value;
    const pct = (v?: number) => (v === undefined ? '-' : `${v.toFixed(1)} %`);
    cacheSettings = [
      { label: 'Cache allocated', value: c.CacheAllocatedInBytes !== undefined ? `${(c.CacheAllocatedInBytes / 1024 ** 3).toFixed(1)} GiB` : '-' },
      { label: 'Cache used', value: pct(c.CacheUsedPercentage) },
      { label: 'Dirty (not yet uploaded)', value: pct(c.CacheDirtyPercentage) },
      { label: 'Cache hit', value: pct(c.CacheHitPercentage) },
      { label: 'Cache miss', value: pct(c.CacheMissPercentage) },
      { label: 'Cache disks', value: (c.DiskIds || []).join(', ') || '-' },
    ];
  } else if (!unsupported(cache.reason)) errors.push(errorText('Cache', cache.reason));

  return {
    gatewayArn: info.GatewayARN || arn,
    gatewayId: info.GatewayId,
    gatewayName: info.GatewayName,
    gatewayType: info.GatewayType,
    operationalState: info.GatewayState,
    gatewayState: info.GatewayState,
    hostEnvironment: info.HostEnvironment,
    ec2InstanceId: info.Ec2InstanceId,
    softwareVersion: info.SoftwareVersion,
    timezone: info.GatewayTimezone,
    endpointType: info.EndpointType,
    vpcEndpoint: info.VPCEndpoint,
    cloudWatchLogGroupArn: info.CloudWatchLogGroupARN,
    lastSoftwareUpdate: info.LastSoftwareUpdate,
    nextUpdateAvailabilityDate: info.NextUpdateAvailabilityDate,
    softwareUpdatesEndDate: info.SoftwareUpdatesEndDate,
    deprecationDate: info.DeprecationDate,
    gatewayCapacity: info.GatewayCapacity,
    networkInterfaces: (info.GatewayNetworkInterfaces || []).map((n) => [n.Ipv4Address, n.Ipv6Address].filter(Boolean).join(' / ')).filter(Boolean),
    maintenance,
    bandwidth,
    cache: cacheSettings,
    tags: (info.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
    errors,
  };
}

/** Volumes, file shares, tapes and local disks - what applies depends on the gateway type. */
export async function getStorageGatewayStorage(profile: string, region: string, arn: string): Promise<GatewayStorage> {
  const client = createClient(profile, region);
  const errors: string[] = [];

  const volumes = async () => {
    const out: GatewayStorage['volumes'] = [];
    let Marker: string | undefined;
    do {
      const res = await client.send(new ListVolumesCommand({ GatewayARN: arn, Marker }));
      for (const v of res.VolumeInfos || []) {
        out.push({ volumeArn: v.VolumeARN || '', volumeId: v.VolumeId, volumeType: v.VolumeType, sizeInBytes: v.VolumeSizeInBytes, attachmentStatus: v.VolumeAttachmentStatus });
      }
      Marker = res.Marker;
    } while (Marker);
    return out;
  };

  const fileShares = async () => {
    const out: GatewayStorage['fileShares'] = [];
    let Marker: string | undefined;
    do {
      const res = await client.send(new ListFileSharesCommand({ GatewayARN: arn, Marker }));
      for (const f of res.FileShareInfoList || []) {
        out.push({ fileShareArn: f.FileShareARN || '', fileShareId: f.FileShareId, type: f.FileShareType, status: f.FileShareStatus });
      }
      Marker = res.NextMarker;
    } while (Marker);
    // Path and S3 location come from the per-protocol describe calls (max 10 ARNs each).
    const fill = async (type: 'NFS' | 'SMB') => {
      const arns = out.filter((f) => f.type === type).map((f) => f.fileShareArn);
      for (let i = 0; i < arns.length; i += 10) {
        const chunk = arns.slice(i, i + 10);
        const infos =
          type === 'NFS'
            ? (await client.send(new DescribeNFSFileSharesCommand({ FileShareARNList: chunk }))).NFSFileShareInfoList || []
            : (await client.send(new DescribeSMBFileSharesCommand({ FileShareARNList: chunk }))).SMBFileShareInfoList || [];
        for (const info of infos) {
          const target = out.find((f) => f.fileShareArn === info.FileShareARN);
          if (target) {
            target.path = info.Path;
            target.locationArn = info.LocationARN;
          }
        }
      }
    };
    await Promise.all([fill('NFS'), fill('SMB')]).catch((err) => errors.push(errorText('File share details', err)));
    return out;
  };

  const tapes = async () => {
    const tapeArns: string[] = [];
    let Marker: string | undefined;
    do {
      const res = await client.send(new ListTapesCommand({ Marker }));
      for (const t of res.TapeInfos || []) if (t.GatewayARN === arn && t.TapeARN) tapeArns.push(t.TapeARN);
      Marker = res.Marker;
    } while (Marker && tapeArns.length < 1000);
    if (tapeArns.length === 0) return [];
    const res = await client.send(new DescribeTapesCommand({ GatewayARN: arn, TapeARNs: tapeArns.slice(0, 1000) }));
    return (res.Tapes || []).map((t) => ({ tapeArn: t.TapeARN || '', barcode: t.TapeBarcode, sizeInBytes: t.TapeSizeInBytes, status: t.TapeStatus, poolId: t.PoolId }));
  };

  const disks = async () => {
    const res = await client.send(new ListLocalDisksCommand({ GatewayARN: arn }));
    return (res.Disks || []).map((d) => ({ diskId: d.DiskId || '', path: d.DiskPath, sizeInBytes: d.DiskSizeInBytes, status: d.DiskStatus, allocationType: d.DiskAllocationType }));
  };

  const [v, f, t, d] = await Promise.allSettled([volumes(), fileShares(), tapes(), disks()]);
  const pick = <T>(r: PromiseSettledResult<T[]>, label: string): T[] => {
    if (r.status === 'fulfilled') return r.value;
    if (!unsupported(r.reason)) errors.push(errorText(label, r.reason));
    return [];
  };
  return { volumes: pick(v, 'Volumes'), fileShares: pick(f, 'File shares'), tapes: pick(t, 'Tapes'), disks: pick(d, 'Local disks'), errors };
}

export async function addStorageGatewayTag(profile: string, region: string, arn: string, key: string, value: string): Promise<GatewayDetail> {
  await createClient(profile, region).send(new AddTagsToResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  return getStorageGateway(profile, region, arn);
}

export async function removeStorageGatewayTag(profile: string, region: string, arn: string, key: string): Promise<GatewayDetail> {
  await createClient(profile, region).send(new RemoveTagsFromResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  return getStorageGateway(profile, region, arn);
}
