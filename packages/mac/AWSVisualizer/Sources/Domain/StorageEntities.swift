import Foundation

// Models for EFS, FSx, EBS, S3 Glacier, Storage Gateway and AWS Backup.
// Field names match packages/api/src/domain/entities/storage.ts.

struct StorageSetting: Codable, Hashable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

extension Array where Element == StorageSetting {
    var detailItems: [DetailItem] { map { DetailItem($0.label, $0.value) } }
}

// MARK: - EFS

struct EfsFileSystemSummary: Codable, Identifiable, Hashable {
    var id: String { fileSystemId }
    let fileSystemId: String
    let name: String?
    let lifeCycleState: String?
    let sizeInBytes: Int?
    let performanceMode: String?
    let throughputMode: String?
    let encrypted: Bool?
    let numberOfMountTargets: Int?
    let availabilityZoneName: String?
    let creationTime: String?
}

struct EfsFileSystemDetail: Codable {
    let fileSystemId: String
    let name: String?
    let lifeCycleState: String?
    let sizeInBytes: Int?
    let performanceMode: String?
    let throughputMode: String?
    let encrypted: Bool?
    let numberOfMountTargets: Int?
    let availabilityZoneName: String?
    let creationTime: String?
    let fileSystemArn: String?
    let ownerId: String?
    let creationToken: String?
    let kmsKeyId: String?
    let provisionedThroughputInMibps: Double?
    let sizeInStandard: Int?
    let sizeInIA: Int?
    let sizeInArchive: Int?
    let sizeTimestamp: String?
    let replicationOverwriteProtection: String?
    let automaticBackups: String?
    let lifecyclePolicies: [String]
    let dnsName: String
    let tags: [ResourceTag]
}

struct EfsMountTarget: Codable, Identifiable, Hashable {
    var id: String { mountTargetId }
    let mountTargetId: String
    let subnetId: String?
    let vpcId: String?
    let availabilityZoneName: String?
    let ipAddress: String?
    let networkInterfaceId: String?
    let lifeCycleState: String?
    let securityGroups: [String]
}

struct EfsAccessPoint: Codable, Identifiable, Hashable {
    var id: String { accessPointId }
    let accessPointId: String
    let accessPointArn: String?
    let name: String?
    let lifeCycleState: String?
    let path: String?
    let posixUser: String?
    let creationInfo: String?
}

struct EfsReplicationDestination: Codable, Hashable {
    let fileSystemId: String?
    let region: String?
    let status: String?
    let lastReplicatedTimestamp: String?
}

struct EfsReplication: Codable, Hashable {
    let sourceFileSystemId: String?
    let sourceRegion: String?
    let isSource: Bool
    let creationTime: String?
    let destinations: [EfsReplicationDestination]
}

struct EfsFileSystemExtras: Codable {
    let mountTargets: [EfsMountTarget]
    let accessPoints: [EfsAccessPoint]
    let replications: [EfsReplication]
    let policy: String?
    let errors: [String]
}

// MARK: - FSx

struct FsxFileSystemSummary: Codable, Identifiable, Hashable {
    var id: String { fileSystemId }
    let fileSystemId: String
    let name: String?
    let fileSystemType: String?
    let lifecycle: String?
    let storageCapacity: Int?
    let storageType: String?
    let deploymentType: String?
    let throughputCapacity: Int?
    let creationTime: String?
}

struct FsxAdministrativeAction: Codable, Hashable {
    let type: String?
    let status: String?
    let progressPercent: Int?
    let requestTime: String?
    let failure: String?
}

struct FsxFileSystemDetail: Codable {
    let fileSystemId: String
    let name: String?
    let fileSystemType: String?
    let lifecycle: String?
    let storageCapacity: Int?
    let storageType: String?
    let deploymentType: String?
    let throughputCapacity: Int?
    let creationTime: String?
    let resourceArn: String?
    let ownerId: String?
    let fileSystemTypeVersion: String?
    let vpcId: String?
    let subnetIds: [String]
    let networkInterfaceIds: [String]
    let dnsName: String?
    let kmsKeyId: String?
    let failureMessage: String?
    let settings: [StorageSetting]
    let backupSettings: [StorageSetting]
    let endpoints: [StorageSetting]
    let administrativeActions: [FsxAdministrativeAction]
    let tags: [ResourceTag]
}

struct FsxBackup: Codable, Identifiable, Hashable {
    var id: String { backupId }
    let backupId: String
    let type: String?
    let lifecycle: String?
    let progressPercent: Int?
    let creationTime: String?
    let resourceType: String?
    let volumeId: String?
    let failureMessage: String?
}

struct FsxVolume: Codable, Identifiable, Hashable {
    var id: String { volumeId }
    let volumeId: String
    let name: String?
    let volumeType: String?
    let lifecycle: String?
    let storageVirtualMachineId: String?
    let path: String?
    let sizeInBytes: Int?
    let settings: [StorageSetting]
}

struct FsxStorageVirtualMachine: Codable, Identifiable, Hashable {
    var id: String { storageVirtualMachineId }
    let storageVirtualMachineId: String
    let name: String?
    let lifecycle: String?
    let subtype: String?
    let rootVolumeSecurityStyle: String?
    let activeDirectory: String?
    let endpoints: [StorageSetting]
}

struct FsxDataRepositoryAssociation: Codable, Identifiable, Hashable {
    var id: String { associationId }
    let associationId: String
    let lifecycle: String?
    let fileSystemPath: String?
    let dataRepositoryPath: String?
    let autoImport: String?
    let autoExport: String?
}

struct FsxFileSystemExtras: Codable {
    let backups: [FsxBackup]
    let volumes: [FsxVolume]
    let storageVirtualMachines: [FsxStorageVirtualMachine]
    let dataRepositoryAssociations: [FsxDataRepositoryAssociation]
    let errors: [String]
}

// MARK: - EBS

struct EbsVolumeAttachment: Codable, Hashable {
    let instanceId: String?
    let device: String?
    let state: String?
    let attachTime: String?
    let deleteOnTermination: Bool?
}

struct EbsVolume: Codable, Identifiable, Hashable {
    var id: String { volumeId }
    let volumeId: String
    let name: String?
    let volumeType: String?
    let size: Int?
    let iops: Int?
    let throughput: Int?
    let state: String?
    let availabilityZone: String?
    let encrypted: Bool?
    let kmsKeyId: String?
    let snapshotId: String?
    let multiAttachEnabled: Bool?
    let createTime: String?
    let attachments: [EbsVolumeAttachment]
    let tags: [ResourceTag]
}

struct EbsVolumeStatusEvent: Codable, Hashable {
    let type: String?
    let description: String?
    let notBefore: String?
    let notAfter: String?
}

struct EbsVolumeStatusAction: Codable, Hashable {
    let code: String?
    let description: String?
}

struct EbsVolumeStatus: Codable, Hashable {
    let status: String?
    let ioEnabled: String?
    let ioPerformance: String?
    let events: [EbsVolumeStatusEvent]
    let actions: [EbsVolumeStatusAction]
}

struct EbsSnapshot: Codable, Identifiable, Hashable {
    var id: String { snapshotId }
    let snapshotId: String
    let name: String?
    let description: String?
    let volumeId: String?
    let volumeSize: Int?
    let state: String?
    let progress: String?
    let startTime: String?
    let encrypted: Bool?
    let kmsKeyId: String?
    let storageTier: String?
    let ownerId: String?
    let tags: [ResourceTag]
}

struct EbsSnapshotPage: Codable {
    let snapshots: [EbsSnapshot]
    let truncated: Bool
}

struct EbsVolumeDetail: Codable {
    let volume: EbsVolume
    let status: EbsVolumeStatus?
    let snapshots: [EbsSnapshot]
    let errors: [String]
}

// MARK: - S3 Glacier

struct GlacierVault: Codable, Identifiable, Hashable {
    var id: String { vaultName }
    let vaultName: String
    let vaultArn: String?
    let creationDate: String?
    let lastInventoryDate: String?
    let numberOfArchives: Int?
    let sizeInBytes: Int?
}

struct GlacierVaultLock: Codable, Hashable {
    let state: String?
    let policy: String?
    let creationDate: String?
    let expirationDate: String?
}

struct GlacierVaultNotifications: Codable, Hashable {
    let snsTopic: String?
    let events: [String]
}

struct GlacierVaultDetail: Codable {
    let vaultName: String
    let vaultArn: String?
    let creationDate: String?
    let lastInventoryDate: String?
    let numberOfArchives: Int?
    let sizeInBytes: Int?
    let accessPolicy: String?
    let lock: GlacierVaultLock?
    let notifications: GlacierVaultNotifications?
    let tags: [ResourceTag]
}

struct GlacierJob: Codable, Identifiable, Hashable {
    var id: String { jobId }
    let jobId: String
    let action: String?
    let description: String?
    let statusCode: String?
    let statusMessage: String?
    let completed: Bool?
    let creationDate: String?
    let completionDate: String?
    let tier: String?
    let archiveId: String?
    let archiveSizeInBytes: Int?
    let inventorySizeInBytes: Int?
}

struct GlacierArchive: Codable, Identifiable, Hashable {
    var id: String { archiveId }
    let archiveId: String
    let description: String?
    let creationDate: String?
    let size: Int?
    let sha256TreeHash: String?
}

struct GlacierInventory: Codable {
    let inventoryDate: String?
    let archives: [GlacierArchive]
    let truncated: Bool
}

struct GlacierJobStarted: Codable {
    let jobId: String?
}

// MARK: - Storage Gateway

struct GatewaySummary: Codable, Identifiable, Hashable {
    var id: String { gatewayArn }
    let gatewayArn: String
    let gatewayId: String?
    let gatewayName: String?
    let gatewayType: String?
    let operationalState: String?
    let hostEnvironment: String?
    let ec2InstanceId: String?
    let softwareVersion: String?
}

struct GatewayDetail: Codable {
    let gatewayArn: String
    let gatewayId: String?
    let gatewayName: String?
    let gatewayType: String?
    let operationalState: String?
    let hostEnvironment: String?
    let ec2InstanceId: String?
    let softwareVersion: String?
    let gatewayState: String?
    let timezone: String?
    let endpointType: String?
    let vpcEndpoint: String?
    let cloudWatchLogGroupArn: String?
    let lastSoftwareUpdate: String?
    let nextUpdateAvailabilityDate: String?
    let softwareUpdatesEndDate: String?
    let deprecationDate: String?
    let gatewayCapacity: String?
    let networkInterfaces: [String]
    let maintenance: String?
    let bandwidth: [StorageSetting]
    let cache: [StorageSetting]
    let tags: [ResourceTag]
    let errors: [String]
}

struct GatewayVolume: Codable, Identifiable, Hashable {
    var id: String { volumeArn }
    let volumeArn: String
    let volumeId: String?
    let volumeType: String?
    let sizeInBytes: Int?
    let attachmentStatus: String?
}

struct GatewayFileShare: Codable, Identifiable, Hashable {
    var id: String { fileShareArn }
    let fileShareArn: String
    let fileShareId: String?
    let type: String?
    let status: String?
    let path: String?
    let locationArn: String?
}

struct GatewayTape: Codable, Identifiable, Hashable {
    var id: String { tapeArn }
    let tapeArn: String
    let barcode: String?
    let sizeInBytes: Int?
    let status: String?
    let poolId: String?
}

struct GatewayDisk: Codable, Identifiable, Hashable {
    var id: String { diskId }
    let diskId: String
    let path: String?
    let sizeInBytes: Int?
    let status: String?
    let allocationType: String?
}

struct GatewayStorage: Codable {
    let volumes: [GatewayVolume]
    let fileShares: [GatewayFileShare]
    let tapes: [GatewayTape]
    let disks: [GatewayDisk]
    let errors: [String]
}

// MARK: - AWS Backup

struct BackupPlanSummary: Codable, Identifiable, Hashable {
    var id: String { backupPlanId }
    let backupPlanId: String
    let backupPlanArn: String?
    let backupPlanName: String?
    let versionId: String?
    let creationDate: String?
    let lastExecutionDate: String?
}

struct BackupRuleInfo: Codable, Identifiable, Hashable {
    var id: String { ruleName }
    let ruleName: String
    let targetVault: String?
    let schedule: String?
    let timezone: String?
    let startWindowMinutes: Int?
    let completionWindowMinutes: Int?
    let moveToColdStorageAfterDays: Int?
    let deleteAfterDays: Int?
    let continuousBackup: Bool?
    let copyTo: [String]
}

struct BackupSelectionInfo: Codable, Identifiable, Hashable {
    var id: String { selectionId }
    let selectionId: String
    let selectionName: String?
    let iamRoleArn: String?
    let resources: [String]
    let notResources: [String]
    let conditions: [String]
}

struct BackupPlanDetail: Codable {
    let backupPlanId: String
    let backupPlanArn: String?
    let backupPlanName: String?
    let versionId: String?
    let creationDate: String?
    let lastExecutionDate: String?
    let rules: [BackupRuleInfo]
    let selections: [BackupSelectionInfo]
    let advancedSettings: [String]
    let tags: [ResourceTag]
}

struct BackupVaultSummary: Codable, Identifiable, Hashable {
    var id: String { backupVaultName }
    let backupVaultName: String
    let backupVaultArn: String?
    let vaultType: String?
    let vaultState: String?
    let creationDate: String?
    let encryptionKeyArn: String?
    let numberOfRecoveryPoints: Int?
    let locked: Bool?
    let minRetentionDays: Int?
    let maxRetentionDays: Int?
    let lockDate: String?
}

struct BackupRecoveryPoint: Codable, Identifiable, Hashable {
    var id: String { recoveryPointArn }
    let recoveryPointArn: String
    let resourceArn: String?
    let resourceName: String?
    let resourceType: String?
    let status: String?
    let creationDate: String?
    let completionDate: String?
    let backupSizeInBytes: Int?
    let deleteAt: String?
    let moveToColdStorageAt: String?
    let isEncrypted: Bool?
    let createdByPlan: String?
}

struct BackupVaultNotifications: Codable, Hashable {
    let snsTopicArn: String?
    let events: [String]
}

struct BackupVaultDetail: Codable {
    let backupVaultName: String
    let backupVaultArn: String?
    let vaultType: String?
    let vaultState: String?
    let creationDate: String?
    let encryptionKeyArn: String?
    let numberOfRecoveryPoints: Int?
    let locked: Bool?
    let minRetentionDays: Int?
    let maxRetentionDays: Int?
    let lockDate: String?
    let recoveryPoints: [BackupRecoveryPoint]
    let recoveryPointsTruncated: Bool
    let accessPolicy: String?
    let notifications: BackupVaultNotifications?
    let tags: [ResourceTag]
    let errors: [String]
}

struct BackupProtectedResource: Codable, Identifiable, Hashable {
    var id: String { resourceArn }
    let resourceArn: String
    let resourceName: String?
    let resourceType: String?
    let lastBackupTime: String?
    let lastBackupVault: String?
}

struct BackupJobInfo: Codable, Identifiable, Hashable {
    var id: String { jobId }
    let jobId: String
    let kind: String
    let state: String?
    let statusMessage: String?
    let resourceArn: String?
    let resourceName: String?
    let resourceType: String?
    let vault: String?
    let creationDate: String?
    let completionDate: String?
    let percentDone: String?
    let sizeInBytes: Int?
}

struct BackupOverview: Codable {
    let plans: [BackupPlanSummary]
    let vaults: [BackupVaultSummary]
    let protectedResources: [BackupProtectedResource]
    let errors: [String]
}
