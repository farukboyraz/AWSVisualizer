import {
  FSxClient,
  DescribeFileSystemsCommand,
  DescribeBackupsCommand,
  DescribeVolumesCommand,
  DescribeStorageVirtualMachinesCommand,
  DescribeDataRepositoryAssociationsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type FileSystem,
  type DiskIopsConfiguration,
} from '@aws-sdk/client-fsx';
import { cachedCredentials } from './credential-cache.js';
import type {
  FsxFileSystemSummary,
  FsxFileSystemDetail,
  FsxFileSystemExtras,
  StorageSetting,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): FSxClient {
  return new FSxClient({ region, credentials: cachedCredentials(profile) });
}

const errorText = (label: string, err: unknown) => `${label}: ${err instanceof Error ? err.message : String(err)}`;

/** Drops undefined values so the UI grid only shows what the file system type has. */
function settings(pairs: [string, unknown][]): StorageSetting[] {
  return pairs
    .filter(([, v]) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0))
    .map(([label, v]) => ({ label, value: Array.isArray(v) ? v.join(', ') : typeof v === 'boolean' ? (v ? 'Enabled' : 'Disabled') : String(v) }));
}

const iops = (d?: DiskIopsConfiguration) => (d ? `${d.Iops ?? '-'} (${d.Mode ?? '-'})` : undefined);
const nameTag = (fs: FileSystem) => fs.Tags?.find((t) => t.Key === 'Name')?.Value;

function typeConfig(fs: FileSystem) {
  return fs.WindowsConfiguration || fs.LustreConfiguration || fs.OntapConfiguration || fs.OpenZFSConfiguration;
}

function throughputOf(fs: FileSystem): number | undefined {
  return (
    fs.WindowsConfiguration?.ThroughputCapacity ??
    fs.OntapConfiguration?.ThroughputCapacity ??
    fs.OpenZFSConfiguration?.ThroughputCapacity ??
    fs.LustreConfiguration?.PerUnitStorageThroughput
  );
}

function mapSummary(fs: FileSystem): FsxFileSystemSummary {
  return {
    fileSystemId: fs.FileSystemId || '',
    name: nameTag(fs),
    fileSystemType: fs.FileSystemType,
    lifecycle: fs.Lifecycle,
    storageCapacity: fs.StorageCapacity,
    storageType: fs.StorageType,
    deploymentType: typeConfig(fs)?.DeploymentType,
    throughputCapacity: throughputOf(fs),
    creationTime: fs.CreationTime?.toISOString(),
  };
}

export async function listFsxFileSystems(profile: string, region: string): Promise<FsxFileSystemSummary[]> {
  const client = createClient(profile, region);
  const out: FsxFileSystemSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new DescribeFileSystemsCommand({ NextToken }));
    out.push(...(res.FileSystems || []).map(mapSummary));
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => (a.name || a.fileSystemId).localeCompare(b.name || b.fileSystemId));
}

export async function getFsxFileSystem(profile: string, region: string, id: string): Promise<FsxFileSystemDetail> {
  const res = await createClient(profile, region).send(new DescribeFileSystemsCommand({ FileSystemIds: [id] }));
  const fs = res.FileSystems?.[0];
  if (!fs) throw new Error(`File system not found: ${id}`);
  const w = fs.WindowsConfiguration;
  const l = fs.LustreConfiguration;
  const o = fs.OntapConfiguration;
  const z = fs.OpenZFSConfiguration;
  const c = typeConfig(fs);

  let typeSettings: StorageSetting[] = [];
  let endpoints: StorageSetting[] = [];
  if (w) {
    typeSettings = settings([
      ['Deployment type', w.DeploymentType],
      ['Throughput capacity', w.ThroughputCapacity !== undefined ? `${w.ThroughputCapacity} MB/s` : undefined],
      ['SSD IOPS', iops(w.DiskIopsConfiguration)],
      ['Active Directory', w.ActiveDirectoryId || w.SelfManagedActiveDirectoryConfiguration?.DomainName],
      ['Preferred subnet', w.PreferredSubnetId],
      ['File access auditing', w.AuditLogConfiguration?.FileAccessAuditLogLevel],
      ['Maintenance in progress', w.MaintenanceOperationsInProgress],
    ]);
    endpoints = settings([
      ['DNS name', fs.DNSName],
      ['Preferred file server IP', w.PreferredFileServerIp],
      ['Remote PowerShell endpoint', w.RemoteAdministrationEndpoint],
      ['Aliases', (w.Aliases || []).map((a) => `${a.Name} (${a.Lifecycle})`)],
    ]);
  } else if (l) {
    typeSettings = settings([
      ['Deployment type', l.DeploymentType],
      ['Throughput per unit of storage', l.PerUnitStorageThroughput !== undefined ? `${l.PerUnitStorageThroughput} MB/s/TiB` : undefined],
      ['Drive cache', l.DriveCacheType],
      ['Data compression', l.DataCompressionType],
      ['Logging', l.LogConfiguration ? `${l.LogConfiguration.Level}${l.LogConfiguration.Destination ? ` → ${l.LogConfiguration.Destination}` : ''}` : undefined],
      ['Root squash', l.RootSquashConfiguration?.RootSquash],
      ['Metadata IOPS', l.MetadataConfiguration ? `${l.MetadataConfiguration.Iops ?? '-'} (${l.MetadataConfiguration.Mode})` : undefined],
      ['Data repository (legacy)', l.DataRepositoryConfiguration?.ImportPath],
    ]);
    endpoints = settings([
      ['DNS name', fs.DNSName],
      ['Mount name', l.MountName],
      ['Mount command', fs.DNSName && l.MountName ? `sudo mount -t lustre ${fs.DNSName}@tcp:/${l.MountName} /fsx` : undefined],
    ]);
  } else if (o) {
    typeSettings = settings([
      ['Deployment type', o.DeploymentType],
      ['Throughput capacity', o.ThroughputCapacity !== undefined ? `${o.ThroughputCapacity} MB/s` : undefined],
      ['HA pairs', o.HAPairs],
      ['Throughput per HA pair', o.ThroughputCapacityPerHAPair !== undefined ? `${o.ThroughputCapacityPerHAPair} MB/s` : undefined],
      ['SSD IOPS', iops(o.DiskIopsConfiguration)],
      ['Preferred subnet', o.PreferredSubnetId],
      ['Endpoint IP address range', o.EndpointIpAddressRange],
      ['Route tables', o.RouteTableIds],
    ]);
    endpoints = settings([
      ['Management DNS name', o.Endpoints?.Management?.DNSName],
      ['Management IPs', o.Endpoints?.Management?.IpAddresses],
      ['Inter-cluster DNS name', o.Endpoints?.Intercluster?.DNSName],
      ['Inter-cluster IPs', o.Endpoints?.Intercluster?.IpAddresses],
    ]);
  } else if (z) {
    typeSettings = settings([
      ['Deployment type', z.DeploymentType],
      ['Throughput capacity', z.ThroughputCapacity !== undefined ? `${z.ThroughputCapacity} MB/s` : undefined],
      ['SSD IOPS', iops(z.DiskIopsConfiguration)],
      ['Root volume', z.RootVolumeId],
      ['Copy tags to volumes', z.CopyTagsToVolumes],
      ['Preferred subnet', z.PreferredSubnetId],
      ['Route tables', z.RouteTableIds],
    ]);
    endpoints = settings([
      ['DNS name', fs.DNSName],
      ['Endpoint IP address', z.EndpointIpAddress],
      ['Endpoint IP address range', z.EndpointIpAddressRange],
    ]);
  }

  const backupSettings = settings([
    ['Automatic backup retention', c?.AutomaticBackupRetentionDays !== undefined ? (c.AutomaticBackupRetentionDays === 0 ? 'Disabled' : `${c.AutomaticBackupRetentionDays} days`) : undefined],
    ['Daily backup window (UTC)', c?.DailyAutomaticBackupStartTime],
    ['Weekly maintenance window (UTC)', c?.WeeklyMaintenanceStartTime],
    ['Copy tags to backups', (w || l || z)?.CopyTagsToBackups],
  ]);

  return {
    ...mapSummary(fs),
    resourceArn: fs.ResourceARN,
    ownerId: fs.OwnerId,
    fileSystemTypeVersion: fs.FileSystemTypeVersion,
    vpcId: fs.VpcId,
    subnetIds: fs.SubnetIds || [],
    networkInterfaceIds: fs.NetworkInterfaceIds || [],
    dnsName: fs.DNSName,
    kmsKeyId: fs.KmsKeyId,
    failureMessage: fs.FailureDetails?.Message,
    settings: typeSettings,
    backupSettings,
    endpoints,
    administrativeActions: (fs.AdministrativeActions || []).map((a) => ({
      type: a.AdministrativeActionType,
      status: a.Status,
      progressPercent: a.ProgressPercent,
      requestTime: a.RequestTime?.toISOString(),
      failure: a.FailureDetails?.Message,
    })),
    tags: (fs.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

/** Backups, Volumes, SVMs and data repository associations - only the parts the file system type has are fetched. */
export async function getFsxFileSystemExtras(profile: string, region: string, id: string, type: string): Promise<FsxFileSystemExtras> {
  const client = createClient(profile, region);
  const filter = [{ Name: 'file-system-id' as const, Values: [id] }];
  const errors: string[] = [];

  const backups = async () => {
    const out: FsxFileSystemExtras['backups'] = [];
    let NextToken: string | undefined;
    do {
      const res = await client.send(new DescribeBackupsCommand({ Filters: filter, NextToken }));
      for (const b of res.Backups || []) {
        out.push({
          backupId: b.BackupId || '',
          type: b.Type,
          lifecycle: b.Lifecycle,
          progressPercent: b.ProgressPercent,
          creationTime: b.CreationTime?.toISOString(),
          resourceType: b.ResourceType,
          volumeId: b.Volume?.VolumeId,
          failureMessage: b.FailureDetails?.Message,
        });
      }
      NextToken = res.NextToken;
    } while (NextToken && out.length < 500);
    return out.sort((a, b) => (b.creationTime || '').localeCompare(a.creationTime || ''));
  };

  const volumes = async () => {
    if (type !== 'ONTAP' && type !== 'OPENZFS') return [];
    const out: FsxFileSystemExtras['volumes'] = [];
    let NextToken: string | undefined;
    do {
      const res = await client.send(new DescribeVolumesCommand({ Filters: filter, NextToken }));
      for (const v of res.Volumes || []) {
        const o = v.OntapConfiguration;
        const z = v.OpenZFSConfiguration;
        out.push({
          volumeId: v.VolumeId || '',
          name: v.Name,
          volumeType: v.VolumeType,
          lifecycle: v.Lifecycle,
          storageVirtualMachineId: o?.StorageVirtualMachineId,
          path: o?.JunctionPath ?? z?.VolumePath,
          sizeInBytes: o?.SizeInBytes ?? (o?.SizeInMegabytes !== undefined ? o.SizeInMegabytes * 1024 * 1024 : undefined),
          settings: o
            ? settings([
                ['Volume type', o.OntapVolumeType],
                ['Security style', o.SecurityStyle],
                ['Storage efficiency', o.StorageEfficiencyEnabled],
                ['Tiering policy', o.TieringPolicy ? `${o.TieringPolicy.Name}${o.TieringPolicy.CoolingPeriod ? ` (${o.TieringPolicy.CoolingPeriod} days)` : ''}` : undefined],
                ['Snapshot policy', o.SnapshotPolicy],
                ['SVM root', o.StorageVirtualMachineRoot],
                ['Style', o.VolumeStyle],
              ])
            : settings([
                ['Parent volume', z?.ParentVolumeId],
                ['Quota', z?.StorageCapacityQuotaGiB !== undefined ? `${z.StorageCapacityQuotaGiB} GiB` : undefined],
                ['Reservation', z?.StorageCapacityReservationGiB !== undefined ? `${z.StorageCapacityReservationGiB} GiB` : undefined],
                ['Record size', z?.RecordSizeKiB !== undefined ? `${z.RecordSizeKiB} KiB` : undefined],
                ['Compression', z?.DataCompressionType],
                ['Read only', z?.ReadOnly],
                ['NFS exports', (z?.NfsExports || []).flatMap((e) => (e.ClientConfigurations || []).map((c) => `${c.Clients} (${(c.Options || []).join(',')})`))],
              ]),
        });
      }
      NextToken = res.NextToken;
    } while (NextToken);
    return out.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  };

  const svms = async () => {
    if (type !== 'ONTAP') return [];
    const res = await client.send(new DescribeStorageVirtualMachinesCommand({ Filters: [{ Name: 'file-system-id', Values: [id] }] }));
    return (res.StorageVirtualMachines || []).map((s) => {
      const e = s.Endpoints;
      return {
        storageVirtualMachineId: s.StorageVirtualMachineId || '',
        name: s.Name,
        lifecycle: s.Lifecycle,
        subtype: s.Subtype,
        rootVolumeSecurityStyle: s.RootVolumeSecurityStyle,
        activeDirectory: s.ActiveDirectoryConfiguration?.SelfManagedActiveDirectoryConfiguration?.DomainName,
        endpoints: settings([
          ['Management', e?.Management?.DNSName],
          ['NFS', e?.Nfs?.DNSName],
          ['SMB', e?.Smb?.DNSName],
          ['iSCSI', e?.Iscsi?.DNSName],
        ]),
      };
    });
  };

  const dras = async () => {
    if (type !== 'LUSTRE') return [];
    const res = await client.send(new DescribeDataRepositoryAssociationsCommand({ Filters: [{ Name: 'file-system-id', Values: [id] }] }));
    return (res.Associations || []).map((a) => ({
      associationId: a.AssociationId || '',
      lifecycle: a.Lifecycle,
      fileSystemPath: a.FileSystemPath,
      dataRepositoryPath: a.DataRepositoryPath,
      autoImport: a.S3?.AutoImportPolicy?.Events?.join(', '),
      autoExport: a.S3?.AutoExportPolicy?.Events?.join(', '),
    }));
  };

  const [b, v, s, d] = await Promise.allSettled([backups(), volumes(), svms(), dras()]);
  const pick = <T>(r: PromiseSettledResult<T>, label: string, fallback: T): T => {
    if (r.status === 'fulfilled') return r.value;
    errors.push(errorText(label, r.reason));
    return fallback;
  };
  return {
    backups: pick(b, 'Backups', []),
    volumes: pick(v, 'Volumes', []),
    storageVirtualMachines: pick(s, 'Storage virtual machines', []),
    dataRepositoryAssociations: pick(d, 'Data repository associations', []),
    errors,
  };
}

export async function addFsxTag(profile: string, region: string, id: string, arn: string, key: string, value: string): Promise<FsxFileSystemDetail> {
  await createClient(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  return getFsxFileSystem(profile, region, id);
}

export async function removeFsxTag(profile: string, region: string, id: string, arn: string, key: string): Promise<FsxFileSystemDetail> {
  await createClient(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  return getFsxFileSystem(profile, region, id);
}
