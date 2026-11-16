import {
  RDSClient,
  DescribeDBInstancesCommand,
  DescribeEventsCommand,
  DescribeDBLogFilesCommand,
  DownloadDBLogFilePortionCommand,
  DescribeDBSnapshotsCommand,
  CreateDBSnapshotCommand,
  StartDBInstanceCommand,
  StopDBInstanceCommand,
  RebootDBInstanceCommand,
  ModifyDBInstanceCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  type DBInstance,
} from '@aws-sdk/client-rds';
import { CloudWatchClient, GetMetricStatisticsCommand, type Statistic } from '@aws-sdk/client-cloudwatch';
import { cachedCredentials } from './credential-cache.js';
import type {
  RdsInstance,
  RdsInstanceDetail,
  RdsEvent,
  RdsLogFile,
  RdsLogContent,
  RdsSnapshot,
  RdsMetricsSummary,
} from '../../domain/entities/index.js';

function createRdsClient(profile: string, region: string): RDSClient {
  return new RDSClient({ region, credentials: cachedCredentials(profile) });
}

export async function listRdsInstances(profile: string, region: string): Promise<RdsInstance[]> {
  const client = createRdsClient(profile, region);
  const command = new DescribeDBInstancesCommand({});
  const response = await client.send(command);

  return (response.DBInstances || []).map((db) => ({
    dbInstanceId: db.DBInstanceIdentifier || '',
    dbInstanceClass: db.DBInstanceClass || '',
    engine: db.Engine || '',
    engineVersion: db.EngineVersion || '',
    status: db.DBInstanceStatus || '',
    endpoint: db.Endpoint?.Address,
    port: db.Endpoint?.Port,
    availabilityZone: db.AvailabilityZone,
    multiAZ: db.MultiAZ || false,
    storageType: db.StorageType || '',
    allocatedStorage: db.AllocatedStorage || 0,
  }));
}

/** Pending modifications, flattened to "Field → value" lines for display. */
function pendingModifications(db: DBInstance): string[] {
  const pending = db.PendingModifiedValues || {};
  return Object.entries(pending)
    .filter(([, v]) => v !== undefined && v !== null && typeof v !== 'object')
    .map(([k, v]) => `${k} → ${String(v)}`);
}

export async function getInstanceDetail(profile: string, region: string, dbInstanceId: string): Promise<RdsInstanceDetail> {
  const client = createRdsClient(profile, region);
  const res = await client.send(new DescribeDBInstancesCommand({ DBInstanceIdentifier: dbInstanceId }));
  const db = res.DBInstances?.[0];
  if (!db) throw new Error('DB instance not found');

  return {
    dbInstanceId: db.DBInstanceIdentifier || '',
    dbInstanceArn: db.DBInstanceArn || '',
    dbInstanceClass: db.DBInstanceClass || '',
    engine: db.Engine || '',
    engineVersion: db.EngineVersion || '',
    status: db.DBInstanceStatus || '',
    endpoint: db.Endpoint?.Address,
    port: db.Endpoint?.Port,
    availabilityZone: db.AvailabilityZone,
    secondaryAvailabilityZone: db.SecondaryAvailabilityZone,
    multiAZ: db.MultiAZ || false,
    publiclyAccessible: db.PubliclyAccessible || false,
    vpcId: db.DBSubnetGroup?.VpcId,
    subnetGroupName: db.DBSubnetGroup?.DBSubnetGroupName,
    subnets: (db.DBSubnetGroup?.Subnets || []).map(
      (s) => `${s.SubnetIdentifier}${s.SubnetAvailabilityZone?.Name ? ` (${s.SubnetAvailabilityZone.Name})` : ''}`
    ),
    securityGroups: (db.VpcSecurityGroups || []).map((g) => `${g.VpcSecurityGroupId}${g.Status ? ` (${g.Status})` : ''}`),
    caCertificateIdentifier: db.CACertificateIdentifier,
    storageType: db.StorageType || '',
    allocatedStorage: db.AllocatedStorage || 0,
    maxAllocatedStorage: db.MaxAllocatedStorage,
    iops: db.Iops,
    storageEncrypted: db.StorageEncrypted || false,
    kmsKeyId: db.KmsKeyId,
    masterUsername: db.MasterUsername,
    dbName: db.DBName,
    parameterGroups: (db.DBParameterGroups || []).map((p) => `${p.DBParameterGroupName} (${p.ParameterApplyStatus})`),
    optionGroups: (db.OptionGroupMemberships || []).map((o) => `${o.OptionGroupName} (${o.Status})`),
    backupRetentionPeriod: db.BackupRetentionPeriod || 0,
    preferredBackupWindow: db.PreferredBackupWindow,
    preferredMaintenanceWindow: db.PreferredMaintenanceWindow,
    latestRestorableTime: db.LatestRestorableTime?.toISOString(),
    autoMinorVersionUpgrade: db.AutoMinorVersionUpgrade || false,
    deletionProtection: db.DeletionProtection || false,
    performanceInsightsEnabled: db.PerformanceInsightsEnabled || false,
    iamAuthEnabled: db.IAMDatabaseAuthenticationEnabled || false,
    dbClusterIdentifier: db.DBClusterIdentifier,
    createdAt: db.InstanceCreateTime?.toISOString(),
    pendingModifiedValues: pendingModifications(db),
    tags: (db.TagList || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

/** Last 7 days of instance events - the console's "Logs & events → Recent events". */
export async function listInstanceEvents(profile: string, region: string, dbInstanceId: string): Promise<RdsEvent[]> {
  const client = createRdsClient(profile, region);
  const res = await client.send(
    new DescribeEventsCommand({ SourceIdentifier: dbInstanceId, SourceType: 'db-instance', Duration: 7 * 24 * 60, MaxRecords: 100 })
  );
  return (res.Events || [])
    .map((e) => ({ date: e.Date?.toISOString(), message: e.Message || '', categories: e.EventCategories || [] }))
    .sort((a, b) => (b.date || '').localeCompare(a.date || ''));
}

export async function listLogFiles(profile: string, region: string, dbInstanceId: string): Promise<RdsLogFile[]> {
  const client = createRdsClient(profile, region);
  const files: RdsLogFile[] = [];
  let marker: string | undefined;
  do {
    const res = await client.send(new DescribeDBLogFilesCommand({ DBInstanceIdentifier: dbInstanceId, Marker: marker }));
    for (const f of res.DescribeDBLogFiles || []) {
      files.push({
        logFileName: f.LogFileName || '',
        lastWritten: f.LastWritten ? new Date(f.LastWritten).toISOString() : undefined,
        size: f.Size || 0,
      });
    }
    marker = res.Marker;
  } while (marker && files.length < 1000);
  return files.sort((a, b) => (b.lastWritten || '').localeCompare(a.lastWritten || ''));
}

/**
 * Tail of a log file. With `NumberOfLines` and no `Marker`, RDS returns the
 * most recent lines - the console's "View" shows the same tail rather than
 * the whole file (which can be gigabytes).
 */
export async function getLogTail(profile: string, region: string, dbInstanceId: string, logFileName: string, lines = 500): Promise<RdsLogContent> {
  const client = createRdsClient(profile, region);
  const res = await client.send(
    new DownloadDBLogFilePortionCommand({ DBInstanceIdentifier: dbInstanceId, LogFileName: logFileName, NumberOfLines: lines })
  );
  // SQL Server writes its logs as UTF-16 with a BOM, which comes through
  // the API as a stray "ÿþ" (or U+FEFF) prefix on the first chunk.
  const content = (res.LogFileData || '').replace(/^(\uFEFF|\u00FF\u00FE)/, '');
  return { logFileName, content, truncated: res.AdditionalDataPending || false };
}

export async function listSnapshots(profile: string, region: string, dbInstanceId: string): Promise<RdsSnapshot[]> {
  const client = createRdsClient(profile, region);
  const res = await client.send(new DescribeDBSnapshotsCommand({ DBInstanceIdentifier: dbInstanceId, MaxRecords: 100 }));
  return (res.DBSnapshots || [])
    .map((s) => ({
      snapshotId: s.DBSnapshotIdentifier || '',
      snapshotType: s.SnapshotType,
      status: s.Status,
      createdAt: s.SnapshotCreateTime?.toISOString(),
      allocatedStorage: s.AllocatedStorage,
      engine: s.Engine,
      engineVersion: s.EngineVersion,
      percentProgress: s.PercentProgress,
    }))
    .sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
}

export async function createSnapshot(profile: string, region: string, dbInstanceId: string, snapshotId: string): Promise<void> {
  const client = createRdsClient(profile, region);
  await client.send(new CreateDBSnapshotCommand({ DBInstanceIdentifier: dbInstanceId, DBSnapshotIdentifier: snapshotId }));
}

export async function setInstanceState(profile: string, region: string, dbInstanceId: string, action: 'start' | 'stop' | 'reboot'): Promise<RdsInstanceDetail> {
  const client = createRdsClient(profile, region);
  if (action === 'start') await client.send(new StartDBInstanceCommand({ DBInstanceIdentifier: dbInstanceId }));
  else if (action === 'stop') await client.send(new StopDBInstanceCommand({ DBInstanceIdentifier: dbInstanceId }));
  else await client.send(new RebootDBInstanceCommand({ DBInstanceIdentifier: dbInstanceId }));
  return getInstanceDetail(profile, region, dbInstanceId);
}

/**
 * The two ModifyDBInstance settings exposed here are both applied
 * immediately and neither restarts the instance (deletion protection never
 * does; changing a non-zero retention period to another non-zero value
 * doesn't either - the 0 ↔ non-zero switch that would is rejected below).
 */
export async function modifyInstance(
  profile: string,
  region: string,
  dbInstanceId: string,
  changes: { deletionProtection?: boolean; backupRetentionPeriod?: number }
): Promise<RdsInstanceDetail> {
  const client = createRdsClient(profile, region);
  await client.send(
    new ModifyDBInstanceCommand({
      DBInstanceIdentifier: dbInstanceId,
      DeletionProtection: changes.deletionProtection,
      BackupRetentionPeriod: changes.backupRetentionPeriod,
      ApplyImmediately: true,
    })
  );
  return getInstanceDetail(profile, region, dbInstanceId);
}

export async function addInstanceTag(profile: string, region: string, dbInstanceId: string, arn: string, key: string, value: string): Promise<RdsInstanceDetail> {
  const client = createRdsClient(profile, region);
  await client.send(new AddTagsToResourceCommand({ ResourceName: arn, Tags: [{ Key: key, Value: value }] }));
  return getInstanceDetail(profile, region, dbInstanceId);
}

export async function removeInstanceTag(profile: string, region: string, dbInstanceId: string, arn: string, key: string): Promise<RdsInstanceDetail> {
  const client = createRdsClient(profile, region);
  await client.send(new RemoveTagsFromResourceCommand({ ResourceName: arn, TagKeys: [key] }));
  return getInstanceDetail(profile, region, dbInstanceId);
}

/** Last-24h single-datapoint summary per metric - same approach as Lambda's Monitor tab. */
export async function getInstanceMetrics(profile: string, region: string, dbInstanceId: string): Promise<RdsMetricsSummary> {
  const client = new CloudWatchClient({ region, credentials: cachedCredentials(profile) });
  const endTime = new Date();
  const startTime = new Date(endTime.getTime() - 24 * 60 * 60 * 1000);
  const period = 24 * 60 * 60;
  const dimensions = [{ Name: 'DBInstanceIdentifier', Value: dbInstanceId }];

  const stat = async (metric: string, statistics: Statistic[]) => {
    const res = await client.send(
      new GetMetricStatisticsCommand({ Namespace: 'AWS/RDS', MetricName: metric, Dimensions: dimensions, StartTime: startTime, EndTime: endTime, Period: period, Statistics: statistics })
    );
    return res.Datapoints?.[0];
  };

  const [cpu, connections, storage, memory, readIops, writeIops] = await Promise.all([
    stat('CPUUtilization', ['Average', 'Maximum']),
    stat('DatabaseConnections', ['Average', 'Maximum']),
    stat('FreeStorageSpace', ['Minimum']),
    stat('FreeableMemory', ['Minimum']),
    stat('ReadIOPS', ['Average']),
    stat('WriteIOPS', ['Average']),
  ]);

  return {
    cpuUtilizationAverage: cpu?.Average,
    cpuUtilizationMax: cpu?.Maximum,
    databaseConnectionsAverage: connections?.Average,
    databaseConnectionsMax: connections?.Maximum,
    freeStorageSpaceMin: storage?.Minimum,
    freeableMemoryMin: memory?.Minimum,
    readIopsAverage: readIops?.Average,
    writeIopsAverage: writeIops?.Average,
  };
}
