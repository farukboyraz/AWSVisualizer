import Foundation

// Models for the Compute services beyond EC2 / Lambda / Elastic Beanstalk.
// Field names match packages/api/src/domain/entities/compute.ts.

// MARK: - EC2 Auto Scaling

struct AsgLaunchSource: Codable, Hashable {
    let kind: String
    let name: String?
    let id: String?
    let version: String?

    var display: String {
        guard let name = name ?? id else { return kind }
        return version.map { "\(name) (\($0))" } ?? name
    }
}

struct AsgSummary: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let arn: String
    let desiredCapacity: Int
    let minSize: Int
    let maxSize: Int
    let instanceCount: Int
    let healthyCount: Int
    let status: String?
    let launchSource: AsgLaunchSource
    let availabilityZones: [String]
    let createdTime: String?
}

struct AsgInstance: Codable, Identifiable, Hashable {
    var id: String { instanceId }
    let instanceId: String
    let instanceType: String?
    let availabilityZone: String?
    let lifecycleState: String?
    let healthStatus: String?
    let launchSource: String?
    let protectedFromScaleIn: Bool
}

struct AsgTag: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
    let propagateAtLaunch: Bool
}

struct AsgDetail: Codable {
    let name: String
    let arn: String
    let desiredCapacity: Int
    let minSize: Int
    let maxSize: Int
    let instanceCount: Int
    let healthyCount: Int
    let status: String?
    let launchSource: AsgLaunchSource
    let availabilityZones: [String]
    let createdTime: String?
    let subnetIds: [String]
    let healthCheckType: String?
    let healthCheckGracePeriod: Int?
    let defaultCooldown: Int?
    let defaultInstanceWarmup: Int?
    let terminationPolicies: [String]
    let targetGroupArns: [String]
    let loadBalancerNames: [String]
    let capacityRebalance: Bool
    let maxInstanceLifetime: Int?
    let newInstancesProtectedFromScaleIn: Bool
    let serviceLinkedRoleArn: String?
    let placementGroup: String?
    let suspendedProcesses: [String]
    let enabledMetrics: [String]
    let instanceTypeOverrides: [String]
    let onDemandBaseCapacity: Int?
    let onDemandPercentageAboveBase: Int?
    let spotAllocationStrategy: String?
    let instances: [AsgInstance]
    let asgTags: [AsgTag]
    let tags: [ResourceTag]
}

struct AsgScalingPolicy: Codable, Identifiable, Hashable {
    var id: String { arn }
    let name: String
    let arn: String
    let policyType: String?
    let adjustmentType: String?
    let scalingAdjustment: Int?
    let cooldown: Int?
    let enabled: Bool
    let targetTracking: String?
    let disableScaleIn: Bool?
    let stepAdjustments: [String]
    let alarms: [String]
}

struct AsgScheduledAction: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let recurrence: String?
    let startTime: String?
    let endTime: String?
    let minSize: Int?
    let maxSize: Int?
    let desiredCapacity: Int?
    let timeZone: String?
}

struct AsgScaling: Codable {
    let policies: [AsgScalingPolicy]
    let scheduledActions: [AsgScheduledAction]
}

struct AsgActivity: Codable, Identifiable, Hashable {
    var id: String { activityId }
    let activityId: String
    let description: String?
    let cause: String?
    let statusCode: String?
    let statusMessage: String?
    let startTime: String?
    let endTime: String?
    let progress: Int?
}

struct AsgInstanceRefresh: Codable, Identifiable, Hashable {
    var id: String { instanceRefreshId }
    let instanceRefreshId: String
    let status: String?
    let statusReason: String?
    let startTime: String?
    let endTime: String?
    let percentageComplete: Int?
    let instancesToUpdate: Int?
}

struct AsgActivityPage: Codable {
    let activities: [AsgActivity]
    let instanceRefreshes: [AsgInstanceRefresh]
}

// MARK: - Batch

struct BatchJobQueue: Codable, Identifiable, Hashable {
    var id: String { jobQueueArn }
    let jobQueueName: String
    let jobQueueArn: String
    let state: String?
    let status: String?
    let statusReason: String?
    let priority: Int?
    let computeEnvironments: [String]
    let schedulingPolicyArn: String?
    let tags: [ResourceTag]
}

struct BatchComputeEnvironment: Codable, Identifiable, Hashable {
    var id: String { computeEnvironmentArn }
    let computeEnvironmentName: String
    let computeEnvironmentArn: String
    let type: String?
    let state: String?
    let status: String?
    let statusReason: String?
    let resourceType: String?
    let minvCpus: Int?
    let maxvCpus: Int?
    let desiredvCpus: Int?
    let instanceTypes: [String]
    let allocationStrategy: String?
    let subnets: [String]
    let securityGroupIds: [String]
    let instanceRole: String?
    let launchTemplate: String?
    let serviceRole: String?
    let ecsClusterArn: String?
    let eksClusterArn: String?
    let tags: [ResourceTag]
}

struct BatchJobDefinition: Codable, Identifiable, Hashable {
    var id: String { jobDefinitionArn }
    let jobDefinitionName: String
    let jobDefinitionArn: String
    let revision: Int
    let type: String?
    let status: String?
    let platformCapabilities: [String]
    let image: String?
    let vcpus: String?
    let memory: String?
    let timeoutSeconds: Int?
    let retryAttempts: Int?
    let propagateTags: Bool?
    let propertiesJson: String?
    let parameters: [ResourceTag]
    let tags: [ResourceTag]
}

struct BatchOverview: Codable {
    let jobQueues: [BatchJobQueue]
    let computeEnvironments: [BatchComputeEnvironment]
    let jobDefinitions: [BatchJobDefinition]
}

struct BatchJobSummary: Codable, Identifiable, Hashable {
    var id: String { jobId }
    let jobId: String
    let jobName: String
    let status: String?
    let statusReason: String?
    let createdAt: String?
    let startedAt: String?
    let stoppedAt: String?
    let exitCode: Int?
    let jobDefinition: String?
    let arraySize: Int?
}

struct BatchJobDetail: Codable {
    let jobId: String
    let jobName: String
    let jobArn: String?
    let jobQueue: String?
    let status: String?
    let statusReason: String?
    let createdAt: String?
    let startedAt: String?
    let stoppedAt: String?
    let exitCode: Int?
    let jobDefinition: String?
    let arraySize: Int?
    let attempts: Int
    let image: String?
    let command: [String]
    let vcpus: String?
    let memory: String?
    let logStreamName: String?
    let reason: String?
    let dependsOn: [String]
    let environment: [ResourceTag]
    let tags: [ResourceTag]
}

// MARK: - Lightsail

struct LightsailDisk: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let sizeInGb: Int?
    let path: String?
    let isSystemDisk: Bool
    let iops: Int?
    let state: String?
}

struct LightsailPort: Codable, Hashable, Identifiable {
    var id: String { "\(`protocol` ?? "")-\(range)-\(cidrs.joined(separator: ","))" }
    let fromPort: Int?
    let toPort: Int?
    let `protocol`: String?
    let state: String?
    let cidrs: [String]

    var range: String {
        guard let fromPort else { return "-" }
        if let toPort, toPort != fromPort { return "\(fromPort)-\(toPort)" }
        return "\(fromPort)"
    }
}

struct LightsailSnapshot: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let state: String?
    let sizeInGb: Int?
    let createdAt: String?
}

struct LightsailInstance: Codable, Identifiable, Hashable {
    var id: String { arn }
    let name: String
    let arn: String
    let blueprintName: String?
    let bundleId: String?
    let state: String?
    let publicIp: String?
    let privateIp: String?
    let isStaticIp: Bool
    let availabilityZone: String?
    let createdAt: String?
}

struct LightsailInstanceDetail: Codable {
    let name: String
    let arn: String
    let blueprintName: String?
    let bundleId: String?
    let state: String?
    let publicIp: String?
    let privateIp: String?
    let isStaticIp: Bool
    let availabilityZone: String?
    let createdAt: String?
    let blueprintId: String?
    let cpuCount: Int?
    let ramSizeInGb: Double?
    let ipv6Addresses: [String]
    let ipAddressType: String?
    let username: String?
    let sshKeyName: String?
    let monthlyTransferGb: Int?
    let autoSnapshot: String?
    let disks: [LightsailDisk]
    let ports: [LightsailPort]
    let snapshots: [LightsailSnapshot]
    let tags: [ResourceTag]
}

struct LightsailDatabase: Codable, Identifiable, Hashable {
    var id: String { arn }
    let name: String
    let arn: String
    let engine: String?
    let engineVersion: String?
    let state: String?
    let masterUsername: String?
    let masterDatabaseName: String?
    let endpoint: String?
    let bundleId: String?
    let availabilityZone: String?
    let backupRetentionEnabled: Bool
    let publiclyAccessible: Bool
    let preferredBackupWindow: String?
    let preferredMaintenanceWindow: String?
    let createdAt: String?
    let tags: [ResourceTag]
}

struct LightsailContainerService: Codable, Identifiable, Hashable {
    var id: String { arn }
    let name: String
    let arn: String
    let state: String?
    let power: String?
    let scale: Int?
    let url: String?
    let isDisabled: Bool
    let privateDomainName: String?
    let containers: [String]
    let createdAt: String?
    let tags: [ResourceTag]
}

// MARK: - Serverless Application Repository

struct SarApplication: Codable, Identifiable, Hashable {
    var id: String { applicationId }
    let applicationId: String
    let name: String
    let author: String?
    let description: String?
    let creationTime: String?
    let homePageUrl: String?
    let labels: [String]
    let spdxLicenseId: String?
}

struct SarParameter: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String?
    let defaultValue: String?
    let description: String?
    let allowedValues: [String]
}

struct SarVersion: Codable, Identifiable, Hashable {
    var id: String { semanticVersion }
    let semanticVersion: String
    let creationTime: String?
    let sourceCodeUrl: String?
}

struct SarPolicyStatement: Codable, Hashable {
    let statementId: String?
    let principals: [String]
    let actions: [String]
}

struct SarApplicationDetail: Codable {
    let applicationId: String
    let name: String
    let author: String?
    let description: String?
    let creationTime: String?
    let homePageUrl: String?
    let labels: [String]
    let spdxLicenseId: String?
    let isVerifiedAuthor: Bool
    let verifiedAuthorUrl: String?
    let licenseUrl: String?
    let readmeUrl: String?
    let semanticVersion: String?
    let templateUrl: String?
    let sourceCodeUrl: String?
    let requiredCapabilities: [String]
    let resourcesSupported: Bool?
    let parameters: [SarParameter]
    let versions: [SarVersion]
    let policy: [SarPolicyStatement]
    let policyError: String?
}

// MARK: - Outposts

struct Outpost: Codable, Identifiable, Hashable {
    var id: String { outpostId }
    let outpostId: String
    let outpostArn: String
    let name: String
    let description: String?
    let siteId: String?
    let availabilityZone: String?
    let lifeCycleStatus: String?
    let supportedHardwareType: String?
    let ownerId: String?
    let tags: [ResourceTag]
}

struct OutpostAsset: Codable, Identifiable, Hashable {
    var id: String { assetId }
    let assetId: String
    let assetType: String?
    let rackId: String?
    let hostId: String?
    let state: String?
}

struct OutpostDetail: Codable {
    let outpostId: String
    let outpostArn: String
    let name: String
    let description: String?
    let siteId: String?
    let availabilityZone: String?
    let lifeCycleStatus: String?
    let supportedHardwareType: String?
    let ownerId: String?
    let tags: [ResourceTag]
    let siteName: String?
    let siteDescription: String?
    let instanceTypes: [String]
    let assets: [OutpostAsset]
    let assetsError: String?
}

// MARK: - Wavelength / Local Zones

enum EdgeZoneKind: String {
    case wavelength = "wavelength-zone"
    case local = "local-zone"

    var title: String { self == .wavelength ? "Wavelength Zones" : "Local Zones" }
    var singular: String { self == .wavelength ? "Wavelength Zone" : "Local Zone" }
}

struct EdgeZone: Codable, Identifiable, Hashable {
    var id: String { zoneName }
    let zoneName: String
    let zoneId: String?
    let zoneType: String?
    let groupName: String
    let networkBorderGroup: String?
    let optInStatus: String?
    let parentZoneName: String?
    let state: String?

    var isOptedIn: Bool { optInStatus == "opted-in" }
}

struct EdgeZoneSubnet: Codable, Identifiable, Hashable {
    var id: String { subnetId }
    let subnetId: String
    let vpcId: String?
    let cidrBlock: String?
    let availabilityZone: String?
    let availableIpAddressCount: Int?
    let name: String?
}

struct EdgeCarrierGateway: Codable, Identifiable, Hashable {
    var id: String { carrierGatewayId }
    let carrierGatewayId: String
    let vpcId: String?
    let state: String?
    let name: String?
}

struct EdgeZoneGroupDetail: Codable {
    let groupName: String
    let zones: [EdgeZone]
    let subnets: [EdgeZoneSubnet]
    let carrierGateways: [EdgeCarrierGateway]
}

// MARK: - Elastic Beanstalk (environment drill-down)

struct EbStatusCodes: Codable, Hashable {
    let status2xx: Int?
    let status3xx: Int?
    let status4xx: Int?
    let status5xx: Int?
}

struct EbLatency: Codable, Hashable {
    let p999: Double?
    let p99: Double?
    let p95: Double?
    let p90: Double?
    let p75: Double?
    let p50: Double?
    let p10: Double?
}

struct EbInstanceHealth: Codable, Identifiable, Hashable {
    var id: String { instanceId }
    let instanceId: String
    let healthStatus: String?
    let color: String?
    let causes: [String]
    let launchedAt: String?
    let availabilityZone: String?
    let instanceType: String?
    let deploymentVersion: String?
    let deploymentStatus: String?
    let requestCount: Int?
    let latencyP90: Double?
    let cpuUser: Double?
    let cpuIdle: Double?
    let loadAverage1: Double?
}

struct EbInstanceCounts: Codable, Hashable {
    let ok: Int?
    let info: Int?
    let warning: Int?
    let degraded: Int?
    let severe: Int?
    let pending: Int?
    let unknown: Int?
    let noData: Int?
}

struct EbEnvironmentHealth: Codable {
    let enhanced: Bool
    let color: String?
    let healthStatus: String?
    let status: String?
    let causes: [String]
    let refreshedAt: String?
    let requestCount: Int?
    let durationSeconds: Int?
    let statusCodes: EbStatusCodes?
    let latency: EbLatency?
    let instanceCounts: EbInstanceCounts?
    let instances: [EbInstanceHealth]
}

struct EbQueue: Codable, Hashable {
    let name: String
    let url: String?
}

struct EbEnvironmentResources: Codable {
    let instances: [String]
    let autoScalingGroups: [String]
    let loadBalancers: [String]
    let launchTemplates: [String]
    let launchConfigurations: [String]
    let queues: [EbQueue]
    let triggers: [String]
}

struct EbConfigOption: Codable, Identifiable, Hashable {
    var id: String { "\(namespace)|\(optionName)|\(resourceName ?? "")" }
    let namespace: String
    let optionName: String
    let value: String?
    let resourceName: String?
}

struct EbConfiguration: Codable {
    let platformArn: String?
    let solutionStackName: String?
    let deploymentStatus: String?
    let dateUpdated: String?
    let options: [EbConfigOption]

    func value(_ namespace: String, _ option: String) -> String? {
        options.first { $0.namespace == namespace && $0.optionName == option }?.value
    }
}

struct EbApplicationVersion: Codable, Identifiable, Hashable {
    var id: String { versionLabel }
    let versionLabel: String
    let description: String?
    let status: String?
    let dateCreated: String?
    let dateUpdated: String?
    let sourceBundle: String?
    let sourceRepository: String?
    let deployedTo: [String]
}

struct EbLogEntry: Codable, Identifiable, Hashable {
    var id: String { instanceId }
    let instanceId: String
    let sampleTimestamp: String?
    let url: String
    let content: String?
    let truncated: Bool?
}

struct EbManagedAction: Codable, Identifiable, Hashable {
    var id: String { actionId }
    let actionId: String
    let actionType: String?
    let actionDescription: String?
    let status: String?
    let windowStartTime: String?
}

struct EbManagedActionHistoryItem: Codable, Identifiable, Hashable {
    var id: String { "\(actionId)-\(executedTime ?? "")" }
    let actionId: String
    let actionType: String?
    let actionDescription: String?
    let status: String?
    let failureType: String?
    let failureDescription: String?
    let executedTime: String?
    let finishedTime: String?
}

struct EbManagedUpdates: Codable {
    let pending: [EbManagedAction]
    let history: [EbManagedActionHistoryItem]
}
