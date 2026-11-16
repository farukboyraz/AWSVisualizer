// Storage heading: EFS, FSx, EBS, S3 Glacier, Storage Gateway, Backup.

export interface StorageTag {
  key: string;
  value: string;
}

/** A label/value line for type-specific settings the UI shows as a grid. */
export interface StorageSetting {
  label: string;
  value: string;
}

// ---- EFS ----

export interface EfsFileSystemSummary {
  fileSystemId: string;
  name?: string;
  lifeCycleState?: string;
  sizeInBytes?: number;
  performanceMode?: string;
  throughputMode?: string;
  encrypted?: boolean;
  numberOfMountTargets?: number;
  availabilityZoneName?: string;
  creationTime?: string;
}

export interface EfsFileSystemDetail extends EfsFileSystemSummary {
  fileSystemArn?: string;
  ownerId?: string;
  creationToken?: string;
  kmsKeyId?: string;
  provisionedThroughputInMibps?: number;
  sizeInStandard?: number;
  sizeInIA?: number;
  sizeInArchive?: number;
  sizeTimestamp?: string;
  replicationOverwriteProtection?: string;
  automaticBackups?: string;
  lifecyclePolicies: string[];
  dnsName: string;
  tags: StorageTag[];
}

export interface EfsMountTarget {
  mountTargetId: string;
  subnetId?: string;
  vpcId?: string;
  availabilityZoneName?: string;
  ipAddress?: string;
  networkInterfaceId?: string;
  lifeCycleState?: string;
  securityGroups: string[];
}

export interface EfsAccessPoint {
  accessPointId: string;
  accessPointArn?: string;
  name?: string;
  lifeCycleState?: string;
  path?: string;
  posixUser?: string;
  creationInfo?: string;
}

export interface EfsReplication {
  sourceFileSystemId?: string;
  sourceRegion?: string;
  isSource: boolean;
  creationTime?: string;
  destinations: { fileSystemId?: string; region?: string; status?: string; lastReplicatedTimestamp?: string }[];
}

export interface EfsFileSystemExtras {
  mountTargets: EfsMountTarget[];
  accessPoints: EfsAccessPoint[];
  replications: EfsReplication[];
  policy?: string;
  errors: string[];
}

// ---- FSx ----

export interface FsxFileSystemSummary {
  fileSystemId: string;
  name?: string;
  fileSystemType?: string;
  lifecycle?: string;
  storageCapacity?: number;
  storageType?: string;
  deploymentType?: string;
  throughputCapacity?: number;
  creationTime?: string;
}

export interface FsxFileSystemDetail extends FsxFileSystemSummary {
  resourceArn?: string;
  ownerId?: string;
  fileSystemTypeVersion?: string;
  vpcId?: string;
  subnetIds: string[];
  networkInterfaceIds: string[];
  dnsName?: string;
  kmsKeyId?: string;
  failureMessage?: string;
  settings: StorageSetting[];
  backupSettings: StorageSetting[];
  endpoints: StorageSetting[];
  administrativeActions: { type?: string; status?: string; progressPercent?: number; requestTime?: string; failure?: string }[];
  tags: StorageTag[];
}

export interface FsxBackup {
  backupId: string;
  type?: string;
  lifecycle?: string;
  progressPercent?: number;
  creationTime?: string;
  resourceType?: string;
  volumeId?: string;
  failureMessage?: string;
}

export interface FsxVolume {
  volumeId: string;
  name?: string;
  volumeType?: string;
  lifecycle?: string;
  storageVirtualMachineId?: string;
  path?: string;
  sizeInBytes?: number;
  settings: StorageSetting[];
}

export interface FsxStorageVirtualMachine {
  storageVirtualMachineId: string;
  name?: string;
  lifecycle?: string;
  subtype?: string;
  rootVolumeSecurityStyle?: string;
  activeDirectory?: string;
  endpoints: StorageSetting[];
}

export interface FsxDataRepositoryAssociation {
  associationId: string;
  lifecycle?: string;
  fileSystemPath?: string;
  dataRepositoryPath?: string;
  autoImport?: string;
  autoExport?: string;
}

export interface FsxFileSystemExtras {
  backups: FsxBackup[];
  volumes: FsxVolume[];
  storageVirtualMachines: FsxStorageVirtualMachine[];
  dataRepositoryAssociations: FsxDataRepositoryAssociation[];
  errors: string[];
}

// ---- EBS ----

export interface EbsVolumeAttachment {
  instanceId?: string;
  device?: string;
  state?: string;
  attachTime?: string;
  deleteOnTermination?: boolean;
}

export interface EbsVolume {
  volumeId: string;
  name?: string;
  volumeType?: string;
  size?: number;
  iops?: number;
  throughput?: number;
  state?: string;
  availabilityZone?: string;
  encrypted?: boolean;
  kmsKeyId?: string;
  snapshotId?: string;
  multiAttachEnabled?: boolean;
  createTime?: string;
  attachments: EbsVolumeAttachment[];
  tags: StorageTag[];
}

export interface EbsVolumeStatus {
  status?: string;
  ioEnabled?: string;
  ioPerformance?: string;
  events: { type?: string; description?: string; notBefore?: string; notAfter?: string }[];
  actions: { code?: string; description?: string }[];
}

export interface EbsSnapshot {
  snapshotId: string;
  name?: string;
  description?: string;
  volumeId?: string;
  volumeSize?: number;
  state?: string;
  progress?: string;
  startTime?: string;
  encrypted?: boolean;
  kmsKeyId?: string;
  storageTier?: string;
  ownerId?: string;
  tags: StorageTag[];
}

// ---- S3 Glacier ----

export interface GlacierVault {
  vaultName: string;
  vaultArn?: string;
  creationDate?: string;
  lastInventoryDate?: string;
  numberOfArchives?: number;
  sizeInBytes?: number;
}

export interface GlacierVaultDetail extends GlacierVault {
  accessPolicy?: string;
  lock?: { state?: string; policy?: string; creationDate?: string; expirationDate?: string };
  notifications?: { snsTopic?: string; events: string[] };
  tags: StorageTag[];
}

export interface GlacierJob {
  jobId: string;
  action?: string;
  description?: string;
  statusCode?: string;
  statusMessage?: string;
  completed?: boolean;
  creationDate?: string;
  completionDate?: string;
  tier?: string;
  archiveId?: string;
  archiveSizeInBytes?: number;
  inventorySizeInBytes?: number;
}

export interface GlacierInventory {
  inventoryDate?: string;
  archives: { archiveId: string; description?: string; creationDate?: string; size?: number; sha256TreeHash?: string }[];
  truncated: boolean;
}

// ---- Storage Gateway ----

export interface GatewaySummary {
  gatewayArn: string;
  gatewayId?: string;
  gatewayName?: string;
  gatewayType?: string;
  operationalState?: string;
  hostEnvironment?: string;
  ec2InstanceId?: string;
  softwareVersion?: string;
}

export interface GatewayDetail extends GatewaySummary {
  gatewayState?: string;
  timezone?: string;
  endpointType?: string;
  vpcEndpoint?: string;
  cloudWatchLogGroupArn?: string;
  lastSoftwareUpdate?: string;
  nextUpdateAvailabilityDate?: string;
  softwareUpdatesEndDate?: string;
  deprecationDate?: string;
  gatewayCapacity?: string;
  networkInterfaces: string[];
  maintenance?: string;
  bandwidth: StorageSetting[];
  cache: StorageSetting[];
  tags: StorageTag[];
  errors: string[];
}

export interface GatewayStorage {
  volumes: { volumeArn: string; volumeId?: string; volumeType?: string; sizeInBytes?: number; attachmentStatus?: string }[];
  fileShares: { fileShareArn: string; fileShareId?: string; type?: string; status?: string; path?: string; locationArn?: string }[];
  tapes: { tapeArn: string; barcode?: string; sizeInBytes?: number; status?: string; poolId?: string }[];
  disks: { diskId: string; path?: string; sizeInBytes?: number; status?: string; allocationType?: string }[];
  errors: string[];
}

// ---- AWS Backup ----

export interface BackupPlanSummary {
  backupPlanId: string;
  backupPlanArn?: string;
  backupPlanName?: string;
  versionId?: string;
  creationDate?: string;
  lastExecutionDate?: string;
}

export interface BackupRuleInfo {
  ruleName: string;
  targetVault?: string;
  schedule?: string;
  timezone?: string;
  startWindowMinutes?: number;
  completionWindowMinutes?: number;
  moveToColdStorageAfterDays?: number;
  deleteAfterDays?: number;
  continuousBackup?: boolean;
  copyTo: string[];
}

export interface BackupSelectionInfo {
  selectionId: string;
  selectionName?: string;
  iamRoleArn?: string;
  resources: string[];
  notResources: string[];
  conditions: string[];
}

export interface BackupPlanDetail extends BackupPlanSummary {
  rules: BackupRuleInfo[];
  selections: BackupSelectionInfo[];
  advancedSettings: string[];
  tags: StorageTag[];
}

export interface BackupVaultSummary {
  backupVaultName: string;
  backupVaultArn?: string;
  vaultType?: string;
  vaultState?: string;
  creationDate?: string;
  encryptionKeyArn?: string;
  numberOfRecoveryPoints?: number;
  locked?: boolean;
  minRetentionDays?: number;
  maxRetentionDays?: number;
  lockDate?: string;
}

export interface BackupRecoveryPoint {
  recoveryPointArn: string;
  resourceArn?: string;
  resourceName?: string;
  resourceType?: string;
  status?: string;
  creationDate?: string;
  completionDate?: string;
  backupSizeInBytes?: number;
  deleteAt?: string;
  moveToColdStorageAt?: string;
  isEncrypted?: boolean;
  createdByPlan?: string;
}

export interface BackupVaultDetail extends BackupVaultSummary {
  recoveryPoints: BackupRecoveryPoint[];
  recoveryPointsTruncated: boolean;
  accessPolicy?: string;
  notifications?: { snsTopicArn?: string; events: string[] };
  tags: StorageTag[];
  errors: string[];
}

export interface BackupProtectedResource {
  resourceArn: string;
  resourceName?: string;
  resourceType?: string;
  lastBackupTime?: string;
  lastBackupVault?: string;
}

export interface BackupJobInfo {
  jobId: string;
  kind: 'backup' | 'restore' | 'copy';
  state?: string;
  statusMessage?: string;
  resourceArn?: string;
  resourceName?: string;
  resourceType?: string;
  vault?: string;
  creationDate?: string;
  completionDate?: string;
  percentDone?: string;
  sizeInBytes?: number;
}

export interface BackupOverview {
  plans: BackupPlanSummary[];
  vaults: BackupVaultSummary[];
  protectedResources: BackupProtectedResource[];
  errors: string[];
}

export interface EbsVolumeDetail {
  volume: EbsVolume;
  status?: EbsVolumeStatus;
  snapshots: EbsSnapshot[];
  errors: string[];
}
