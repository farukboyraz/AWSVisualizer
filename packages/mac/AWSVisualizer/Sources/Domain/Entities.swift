import Foundation

// MARK: - Auth & Profile

struct AWSProfile: Identifiable, Hashable {
    let name: String
    let region: String
    let roleName: String?
    let accountId: String?
    /// The `[sso-session ...]` this profile signs in through.
    let ssoSession: String?
    /// Whether STS accepted this profile's credentials at the last check.
    /// Invalid profiles stay in the list (flagged) instead of vanishing -
    /// usually it just means their sso-session needs a fresh login.
    let isValid: Bool
    let identity: CallerIdentity?
    /// AWS couldn't be reached at the last check (throttled / offline):
    /// `isValid` is the sidecar's best guess, not a fresh answer.
    var isUnverified = false
    /// When the SSO sign-in runs out, when known.
    var expiresAt: Date?

    var id: String { name }

    var label: String {
        name
    }

    /// Menu label for the profile pickers - expired ones are marked so it's
    /// clear why they'd fail, rather than silently hidden.
    var pickerLabel: String {
        isValid ? name : "\(name)  ⚠︎ session expired"
    }

    init(name: String, region: String, roleName: String? = nil, accountId: String? = nil) {
        self.name = name
        self.region = region
        self.roleName = roleName
        self.accountId = accountId
        self.ssoSession = nil
        self.isValid = true
        self.identity = nil
    }

    init(checkResult: ProfileCheckResult) {
        self.name = checkResult.profile
        self.region = checkResult.region
        self.roleName = checkResult.roleName
        self.accountId = checkResult.accountId
        self.ssoSession = checkResult.ssoSession
        self.isValid = checkResult.valid
        self.identity = checkResult.identity
        self.isUnverified = checkResult.unverified ?? false
        self.expiresAt = checkResult.expiresAt.flatMap(Self.parseDate)
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: text) { return date }
        // ~/.aws/sso/cache writes e.g. "2026-11-17T18:00:00UTC" too.
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(identifier: "UTC")
        legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'UTC'"
        return legacy.date(from: text)
    }

    static func == (lhs: AWSProfile, rhs: AWSProfile) -> Bool {
        lhs.name == rhs.name && lhs.isValid == rhs.isValid && lhs.region == rhs.region && lhs.expiresAt == rhs.expiresAt && lhs.isUnverified == rhs.isUnverified
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

struct CallerIdentity: Codable, Identifiable {
    var id: String { account ?? UUID().uuidString }
    let userId: String?
    let account: String?
    let arn: String?
}

struct ProfileCheckResult: Codable {
    let profile: String
    let region: String
    let ssoSession: String?
    let valid: Bool
    let identity: CallerIdentity?
    let error: String?
    let accountId: String?
    let roleName: String?
    var unverified: Bool?
    var expiresAt: String?
}

struct AccessibleEnvironment: Codable, Identifiable {
    var id: String { "\(accountId):\(roleName)" }
    let accountId: String
    let accountName: String
    let roleName: String
    let ssoSessionName: String
    let ssoRegion: String
    let configuredProfileName: String?
}

struct AccessibleEnvironmentList: Codable {
    let environments: [AccessibleEnvironment]
}

struct AuthResponse<T: Codable>: Codable {
    let authorized: Bool
    let data: T?
    let message: String?
}

extension AuthResponse {
    func loadState<Element>() -> LoadState<[Element]> where T == [Element] {
        guard authorized, let data else {
            return .failed(message ?? "Not authorized")
        }
        return data.isEmpty ? .empty : .loaded(data)
    }
}

// MARK: - Service Catalog

struct AWSServiceCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let icon: String
    let implemented: Bool
    /// Implemented services: whether every npm package they need is installed (nil for the rest).
    var packagesInstalled: Bool?
    /// The last install of this service's packages failed (recorded in ~/.awsvisualizer).
    var packageInstallFailed: Bool?

    /// Implemented, but its SDK packages still have to be installed.
    var needsPackageInstall: Bool { implemented && packagesInstalled == false }
}

struct ServiceCatalogResponse: Codable {
    let services: [AWSServiceCatalogEntry]
}

struct SelectedServicesResponse: Codable {
    let selected: [String]
}

struct FavoriteServicesResponse: Codable {
    let favorites: [String]
}

struct ServiceCountsResponse: Codable {
    let counts: [String: Int?]
}

struct CostPeriod: Codable {
    let start: String?
    let end: String?
}

struct CostSummary: Codable {
    let totalCost: String?
    let currency: String?
    let period: CostPeriod?
    let services: [CostByService]?
    /// Spend per day - or per month when `granularity` is "monthly" (older sidecars don't send it).
    var daily: [CostDay]? = nil
    var granularity: String? = nil
    var view: String? = nil
    /// Date of each `daily` point -> its services, largest first.
    var breakdown: [String: [CostByService]]? = nil

    enum CodingKeys: String, CodingKey {
        case totalCost, currency, period, daily, granularity, view, breakdown
        case services = "serviceBreakdown"
    }
}

struct CostDay: Codable, Identifiable {
    var id: String { date }
    let date: String
    let amount: String
}

struct CostByService: Codable, Identifiable {
    var id: String { serviceName ?? UUID().uuidString }
    let serviceName: String?
    let amount: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case serviceName = "service"
    }
}

// MARK: - Elastic Beanstalk

struct EBEnvironment: Codable, Identifiable {
    var id: String { environmentId ?? environmentName ?? UUID().uuidString }
    let environmentId: String?
    let environmentName: String?
    let applicationName: String?
    let status: String?
    let health: String?
    let healthStatus: String?
    let solutionStackName: String?
    let platformArn: String?
    let versionLabel: String?
    let dateCreated: String?
    let dateUpdated: String?
    let cname: String?
    let endpointURL: String?
}

struct EbEvent: Codable, Identifiable {
    var id: String { "\(eventDate ?? "")-\(message?.prefix(20) ?? "")" }
    let eventDate: String?
    let message: String?
    let severity: String?
    let applicationName: String?
    let environmentName: String?
}

struct EbEnvironmentVariable: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
}

typealias EbTag = ResourceTag

struct EbEnvironmentDetail: Codable {
    let environmentName: String
    let environmentId: String
    let environmentArn: String?
    let applicationName: String
    let status: String
    let health: String
    let healthStatus: String?
    let solutionStackName: String?
    let platformArn: String?
    let versionLabel: String?
    let dateCreated: String?
    let dateUpdated: String?
    let endpointURL: String?
    let cname: String?
    let tier: EbTier?
    let environmentVariables: [EbEnvironmentVariable]
    let tags: [EbTag]
}

struct EbTier: Codable, Hashable {
    let name: String
    let type: String
}

// MARK: - Lambda

struct LambdaFunction: Codable, Identifiable {
    var id: String { functionName ?? UUID().uuidString }
    let functionName: String?
    let runtime: String?
    let handler: String?
    let codeSize: Int?
    let memorySize: Int?
    let timeout: Int?
    let lastModified: String?
    let description: String?
    let state: String?
}

typealias LambdaTag = ResourceTag

struct LambdaFunctionDetail: Codable {
    let functionName: String
    let functionArn: String
    let runtime: String?
    let handler: String?
    let role: String?
    let codeSize: Int
    let memorySize: Int
    let timeout: Int
    let lastModified: String
    let description: String?
    let state: String?
    let stateReason: String?
    let architectures: [String]?
    let packageType: String?
    let environmentVariables: [String: String]
    let reservedConcurrentExecutions: Int?
    let tags: [LambdaTag]
    let codeLocation: String?
}

struct LambdaMetricsSummary: Codable {
    let invocations: Double
    let errors: Double
    let throttles: Double
    let averageDurationMs: Double
    let logGroupName: String
}

struct LambdaVersion: Codable, Identifiable {
    var id: String { version }
    let version: String
    let lastModified: String
    let description: String?
    let codeSize: Int
}

struct LambdaAlias: Codable, Identifiable {
    var id: String { name }
    let name: String
    let functionVersion: String
    let description: String?
    let aliasArn: String
}

struct LambdaEventSourceMapping: Codable, Identifiable {
    var id: String { uuid }
    let uuid: String
    let eventSourceArn: String?
    let functionArn: String?
    let state: String?
    let batchSize: Int?
    let lastModified: String?
    let startingPosition: String?
}

struct LambdaInvokeResult: Codable {
    let statusCode: Int?
    let payload: String?
    let logResult: String?
    let functionError: String?
    let executedVersion: String?
}

// MARK: - EC2

struct Ec2Instance: Codable, Identifiable {
    var id: String { instanceId ?? UUID().uuidString }
    let instanceId: String?
    let instanceType: String?
    let state: String?
    let publicIpAddress: String?
    let privateIpAddress: String?
    let launchTime: String?
    let name: String?
    let platform: String?
    let availabilityZone: String?

    enum CodingKeys: String, CodingKey {
        case instanceId, instanceType, state, launchTime, name, platform, availabilityZone
        case publicIpAddress = "publicIp"
        case privateIpAddress = "privateIp"
    }
}

struct Ec2SecurityGroupRef: Codable, Identifiable, Hashable {
    var id: String { groupId }
    let groupId: String
    let groupName: String
}

typealias Ec2Tag = ResourceTag

struct Ec2InstanceDetail: Codable {
    let instanceId: String
    let instanceType: String
    let state: String
    let name: String
    let privateIp: String?
    let publicIp: String?
    let launchTime: String?
    let platform: String?
    let availabilityZone: String?
    let imageId: String?
    let keyName: String?
    let vpcId: String?
    let subnetId: String?
    let rootDeviceType: String?
    let monitoringEnabled: Bool
    let disableApiTermination: Bool
    let iamInstanceProfileArn: String?
    let securityGroups: [Ec2SecurityGroupRef]
    let tags: [Ec2Tag]
    var architecture: String?
    var privateDnsName: String?
    var publicDnsName: String?
    var rootDeviceName: String?
    var ebsOptimized: Bool?
    var hostname: String?
    var blockDevices: [Ec2BlockDevice]?
    var networkInterfaces: [Ec2NetworkInterface]?
}

struct Ec2BlockDevice: Codable, Identifiable, Hashable {
    var id: String { deviceName }
    let deviceName: String
    let volumeId: String?
    let status: String?
    let attachTime: String?
    let deleteOnTermination: Bool
}

struct Ec2NetworkInterface: Codable, Identifiable, Hashable {
    var id: String { networkInterfaceId }
    let networkInterfaceId: String
    let description: String?
    let privateIp: String?
    let publicIp: String?
    let macAddress: String?
    let subnetId: String?
    let status: String?
}

struct Ec2KeyPair: Codable, Identifiable, Hashable {
    var id: String { keyName }
    let keyName: String
    let keyPairId: String?
}

// MARK: - ECS

struct EcsCluster: Codable, Identifiable {
    var id: String { clusterArn ?? clusterName ?? UUID().uuidString }
    let clusterArn: String?
    let clusterName: String?
    let status: String?
    let runningTasksCount: Int?
    let pendingTasksCount: Int?
    let activeServicesCount: Int?
    let registeredContainerInstancesCount: Int?

    enum CodingKeys: String, CodingKey {
        case clusterArn, clusterName, status
        case runningTasksCount = "runningTasks"
        case pendingTasksCount = "pendingTasks"
        case activeServicesCount = "activeServices"
        case registeredContainerInstancesCount = "registeredContainerInstances"
    }
}

// MARK: - RDS

struct RdsInstance: Codable, Identifiable {
    var id: String { dbInstanceIdentifier ?? UUID().uuidString }
    let dbInstanceIdentifier: String?
    let dbInstanceClass: String?
    let engine: String?
    let engineVersion: String?
    let dbInstanceStatus: String?
    let endpoint: String?
    let port: Int?
    let availabilityZone: String?
    let multiAZ: Bool?
    let storageType: String?
    let allocatedStorage: Int?

    enum CodingKeys: String, CodingKey {
        case dbInstanceClass, engine, engineVersion, endpoint, port, availabilityZone, multiAZ, storageType, allocatedStorage
        case dbInstanceIdentifier = "dbInstanceId"
        case dbInstanceStatus = "status"
    }
}

// MARK: - DynamoDB

struct DdbTableInfo: Codable, Identifiable {
    var id: String { tableName ?? UUID().uuidString }
    let tableName: String?
    let tableStatus: String?
    let itemCount: Int?
    let tableSizeBytes: Int?
    let creationDateTime: String?
    let keySchema: [DdbKeySchemaElement]?
    let attributeDefinitions: [DdbAttributeDefinition]?
    /// GSIs/LSIs - what the Items tab's Query can target.
    let indexes: [DdbIndexInfo]?
}

struct DdbKeySchemaElement: Codable {
    let attributeName: String
    let keyType: String
}

struct DdbAttributeDefinition: Codable {
    let attributeName: String
    let attributeType: String
}

struct DdbScanResult: Codable {
    let items: [[String: DdbAttributeValue]]?
    let count: Int?
    let scannedCount: Int?
    let lastEvaluatedKey: [String: DdbAttributeValue]?
}

/// One call's worth of a whole-table Filter Builder search
/// (`POST /api/dynamodb/search/:name`).
struct DdbSearchResult: Codable {
    let items: [[String: DdbAttributeValue]]
    /// Items examined by this call, matched or not.
    let scannedCount: Int
    /// Opaque resume token of the server's parallel scan - nil once the
    /// whole table has been searched.
    let cursor: String?
    /// Parallel scan segments the server is using.
    let totalSegments: Int
    /// Set when the conditions pin a partition key and the server Queries
    /// that one partition instead of scanning the table.
    let route: DdbSearchRoute?
}

struct DdbSearchRoute: Codable, Equatable {
    let indexName: String?
    let attribute: String
    let value: String
    /// Sort key equality folded into the Query's key condition.
    let sortKey: SortKey?

    struct SortKey: Codable, Equatable {
        let attribute: String
        let value: String
    }

    /// `GSI1PK = "USER#ALL" AND GSI1SK = "X"` - for tooltips.
    var keyCondition: String {
        var text = "\"\(attribute)\" = \"\(value)\""
        if let sortKey { text += " AND \"\(sortKey.attribute)\" = \"\(sortKey.value)\"" }
        return text
    }
}

struct DdbAttributeValue: Codable {
    let value: AnyCodableValue

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = .string(str)
        } else if let int = try? container.decode(Int64.self) {
            value = .integer(int)
        } else if let num = try? container.decode(Double.self) {
            value = .number(num)
        } else if let bool = try? container.decode(Bool.self) {
            value = .bool(bool)
        } else if let arr = try? container.decode([DdbAttributeValue].self) {
            value = .array(arr)
        } else if let obj = try? container.decode([String: DdbAttributeValue].self) {
            value = .object(obj)
        } else if container.decodeNil() {
            value = .null
        } else {
            value = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

enum AnyCodableValue: Codable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case array([DdbAttributeValue])
    case object([String: DdbAttributeValue])
    case null

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .number(let n):
            if n == n.rounded() && n < 1e15 { return String(Int(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[\(a.count) items]"
        case .object(let o): return "{\(o.count) keys}"
        case .null: return "null"
        }
    }

    /// A plain Foundation value (String/NSNumber/Bool/[Any]/[String:Any]/NSNull),
    /// suitable for `JSONSerialization.data(withJSONObject:)` - used to pull a
    /// primary key's value back out of an already-decoded item for DeleteItem.
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .integer(let i): return NSNumber(value: i)
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let a): return a.map { $0.value.jsonValue }
        case .object(let o): return o.mapValues { $0.value.jsonValue }
        case .null: return NSNull()
        }
    }
}

// MARK: - DynamoDB table administration

struct DdbIndexInfo: Codable, Identifiable, Hashable {
    var id: String { indexName }
    let indexName: String
    /// "GSI" | "LSI"
    let indexType: String
    let keySchema: [DdbKeySchemaElement]
    let projectionType: String?
    let nonKeyAttributes: [String]
    let indexStatus: String?
    let itemCount: Int?
    let sizeBytes: Int?
    let readCapacity: Int?
    let writeCapacity: Int?

    static func == (lhs: DdbIndexInfo, rhs: DdbIndexInfo) -> Bool { lhs.indexName == rhs.indexName }
    func hash(into hasher: inout Hasher) { hasher.combine(indexName) }
}

struct DdbTableDetail: Codable {
    let tableName: String
    let tableArn: String
    let tableStatus: String
    let itemCount: Int
    let tableSizeBytes: Int
    let creationDateTime: String?
    let keySchema: [DdbKeySchemaElement]
    let attributeDefinitions: [DdbAttributeDefinition]
    let billingMode: String
    let readCapacity: Int?
    let writeCapacity: Int?
    let tableClass: String?
    let deletionProtection: Bool
    let streamEnabled: Bool
    let streamViewType: String?
    let latestStreamArn: String?
    let encryption: String
    let kmsKeyArn: String?
    let pitrEnabled: Bool
    let earliestRestorableTime: String?
    let latestRestorableTime: String?
    let ttlStatus: String
    let ttlAttribute: String?
    let replicaRegions: [String]
    let indexes: [DdbIndexInfo]
    let tags: [ResourceTag]
}

struct DdbBackup: Codable, Identifiable {
    var id: String { backupArn }
    let backupArn: String
    let backupName: String
    let backupStatus: String?
    let backupType: String?
    let createdAt: String?
    let sizeBytes: Int?
}

struct DdbMetricsSummary: Codable {
    let consumedReadCapacity: Double?
    let consumedWriteCapacity: Double?
    let readThrottleEvents: Double?
    let writeThrottleEvents: Double?
    let getItemLatencyMs: Double?
    let queryLatencyMs: Double?
    let scanLatencyMs: Double?
    let putItemLatencyMs: Double?
}

/// One page of Query / PartiQL results.
struct DdbPageResult: Codable {
    let items: [[String: DdbAttributeValue]]
    let scannedCount: Int?
    let lastEvaluatedKey: [String: DdbAttributeValue]?
    let nextToken: String?
}

// MARK: - S3

struct S3Bucket: Codable, Identifiable {
    var id: String { name ?? UUID().uuidString }
    let name: String?
    let creationDate: String?
    let region: String?
}

struct S3Objects: Codable {
    let objects: [S3Object]?
    let prefixes: [String]?
    let prefix: String?

    enum CodingKeys: String, CodingKey {
        case objects
        case prefixes = "commonPrefixes"
        case prefix
    }
}

struct S3Object: Codable, Identifiable {
    var id: String { key ?? UUID().uuidString }
    let key: String?
    let size: Int?
    let lastModified: String?
    let storageClass: String?
}

struct S3FilePreview: Codable {
    let key: String?
    let contentType: String?
    let size: Int?
    let content: String?
    let isText: Bool?

    enum CodingKeys: String, CodingKey {
        case key, contentType, size, isText
        case content = "body"
    }
}

struct ZipEntry: Codable, Identifiable {
    var id: String { path }
    let path: String
    let isDirectory: Bool
}

struct ZipEntryList: Codable {
    let entries: [ZipEntry]
}

struct ZipEntryContent: Codable {
    let path: String
    let content: String
    let isTruncated: Bool
}

// MARK: - SQS

struct SqsQueue: Codable, Identifiable {
    var id: String { queueUrl ?? queueName ?? UUID().uuidString }
    let queueUrl: String?
    let queueName: String?
    let approximateMessages: Int?
    let approximateMessagesNotVisible: Int?
    let approximateMessagesDelayed: Int?
    let visibilityTimeout: Int?
}

typealias SqsTag = ResourceTag

struct SqsQueueDetail: Codable {
    let queueUrl: String
    let queueName: String
    let arn: String?
    let approximateMessages: Int
    let approximateMessagesNotVisible: Int
    let approximateMessagesDelayed: Int
    let visibilityTimeout: Int
    let messageRetentionPeriod: Int
    let delaySeconds: Int
    let receiveMessageWaitTimeSeconds: Int
    let maximumMessageSize: Int
    let fifoQueue: Bool
    let contentBasedDeduplication: Bool
    let kmsMasterKeyId: String?
    let createdTimestamp: String?
    let lastModifiedTimestamp: String?
    let tags: [SqsTag]
    var policy: String?
    var deadLetterTargetArn: String?
    var maxReceiveCount: Int?
    var sqsManagedSseEnabled: Bool?
    var kmsDataKeyReusePeriodSeconds: Int?
    var fifoThroughputLimit: String?
    var deduplicationScope: String?
}

struct SqsMessage: Codable, Identifiable {
    var id: String { messageId }
    let messageId: String
    let receiptHandle: String
    let body: String
    let sentTimestamp: String?
    let approximateReceiveCount: Int?
}

// MARK: - CloudWatch

struct CloudWatchAlarm: Codable, Identifiable {
    var id: String { alarmName ?? UUID().uuidString }
    let alarmName: String?
    let stateValue: String?
    let metricName: String?
    let namespace: String?
    let threshold: Double?
    let comparisonOperator: String?

    enum CodingKeys: String, CodingKey {
        case alarmName, metricName, namespace, threshold, comparisonOperator
        case stateValue = "state"
    }
}

struct LogGroup: Codable, Identifiable {
    var id: String { logGroupName ?? UUID().uuidString }
    let logGroupName: String?
    let storedBytes: Int?
    let retentionInDays: Int?
    let creationTime: Int?
}

struct CloudWatchAlarmDimension: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let value: String
}

struct CloudWatchAlarmDetail: Codable {
    let alarmName: String
    let alarmArn: String?
    let alarmDescription: String?
    let state: String
    let stateReason: String?
    let actionsEnabled: Bool
    let okActions: [String]
    let alarmActions: [String]
    let insufficientDataActions: [String]
    let metricName: String
    let namespace: String
    let statistic: String?
    let extendedStatistic: String?
    let period: Int?
    let evaluationPeriods: Int?
    let datapointsToAlarm: Int?
    let threshold: Double?
    let comparisonOperator: String?
    let treatMissingData: String?
    let unit: String?
    let dimensions: [CloudWatchAlarmDimension]
}

struct LogStreamInfo: Codable, Identifiable {
    var id: String { logStreamName }
    let logStreamName: String
    let creationTime: Int?
    let firstEventTimestamp: Int?
    let lastEventTimestamp: Int?
    let storedBytes: Int?
}

struct LogEventInfo: Codable, Identifiable {
    var id: String { "\(timestamp ?? 0)-\(message?.hashValue ?? 0)" }
    let timestamp: Int?
    let message: String?
}

// MARK: - CloudFront

struct CloudFrontDistribution: Codable, Identifiable {
    var id: String { distributionId ?? UUID().uuidString }
    let distributionId: String?
    let domainName: String?
    let status: String?
    let enabled: Bool?
    let origins: [String]?
    let lastModifiedTime: String?
    let comment: String?
    let priceClass: String?

    enum CodingKeys: String, CodingKey {
        case domainName, status, enabled, origins, comment, priceClass
        case distributionId = "id"
        case lastModifiedTime = "lastModified"
    }
}

struct CloudFrontOrigin: Codable, Identifiable, Hashable {
    var id: String { originId }
    let originId: String
    let domainName: String
    let originPath: String?
    let type: String

    enum CodingKeys: String, CodingKey {
        case originId = "id"
        case domainName, originPath, type
    }
}

struct CloudFrontCacheBehavior: Codable, Identifiable, Hashable {
    var id: String { pathPattern }
    let pathPattern: String
    let targetOriginId: String
    let viewerProtocolPolicy: String?
    let isDefault: Bool
    var allowedMethods: [String]?
    var compress: Bool?
    var cachePolicyId: String?
    var originRequestPolicyId: String?
}

struct CloudFrontErrorResponse: Codable, Identifiable, Hashable {
    var id: Int { errorCode }
    let errorCode: Int
    let responsePagePath: String?
    let responseCode: String?
    let errorCachingMinTtl: Int?
}

struct CloudFrontInvalidation: Codable, Identifiable, Hashable {
    let id: String
    let status: String
    let createTime: String?
    var paths: [String]?
}

typealias CloudFrontTag = ResourceTag

struct CloudFrontDistributionDetail: Codable {
    let id: String
    let arn: String?
    let domainName: String
    let status: String
    let enabled: Bool
    let comment: String?
    let lastModified: String?
    let priceClass: String?
    let origins: [CloudFrontOrigin]
    let behaviors: [CloudFrontCacheBehavior]
    let tags: [CloudFrontTag]
    var aliases: [String]?
    var defaultRootObject: String?
    var httpVersion: String?
    var ipv6Enabled: Bool?
    var webAclId: String?
    var certificateSource: String?
    var certificateArn: String?
    var minimumProtocolVersion: String?
    var sslSupportMethod: String?
    var geoRestrictionType: String?
    var geoRestrictionLocations: [String]?
    var loggingBucket: String?
    var errorResponses: [CloudFrontErrorResponse]?
}

// MARK: - Route53

struct HostedZone: Codable, Identifiable {
    var id: String { hostedZoneId ?? name ?? UUID().uuidString }
    let hostedZoneId: String?
    let name: String?
    let recordSetCount: Int?
    let comment: String?
    let privateZone: Bool?

    enum CodingKeys: String, CodingKey {
        case name, comment
        case hostedZoneId = "id"
        case recordSetCount = "recordCount"
        case privateZone = "isPrivate"
    }
}

// MARK: - CodeCommit

struct CodeCommitRepository: Codable, Identifiable {
    var id: String { repositoryId }
    let repositoryName: String
    let repositoryId: String
}

struct CodeCommitRepositoryDetail: Codable {
    let repositoryName: String
    let repositoryId: String
    let description: String?
    let defaultBranch: String?
    let cloneUrlHttp: String?
    let arn: String?
    let creationDate: String?
    let lastModifiedDate: String?
    let tags: [CodeCommitTag]
}

typealias CodeCommitTag = ResourceTag

struct CodeCommitBranch: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let commitId: String?
}

// MARK: - Workspace (local git clone: Clone/Pull/Push/Merge)

enum GitOutcome: String, Codable {
    case success
    case conflict
    case rejectedNonFastForward
    case uncommittedChanges
    case nothingToPush
    case error
}

struct GitCommandResult: Codable {
    let outcome: GitOutcome
    let stdout: String
    let stderr: String
    let conflictedFiles: [String]
}

struct WorkspaceStatus: Codable {
    let localPath: String?
    /// `localPath` is set but the folder is missing or no longer a git repo
    /// (moved/deleted outside the app).
    let isMissing: Bool
    let currentBranch: String?
    let isDirty: Bool
    let ahead: Int?
    let behind: Int?
}

struct WorkspaceEntry: Codable, Identifiable {
    var id: String { repositoryName }
    let repositoryName: String
    let localPath: String
}

struct MatchResult: Codable {
    let success: Bool
    let warning: String?
}

struct LocalDiffFile: Codable, Identifiable {
    var id: String { path }
    let path: String
    let changeType: String
    let additions: Int
    let deletions: Int
    let binary: Bool
}

struct CodeCommitFolderEntry: Codable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let isFolder: Bool
}

struct CodeCommitFolderListing: Codable {
    let path: String
    let commitId: String
    let entries: [CodeCommitFolderEntry]
}

struct CodeCommitFileContent: Codable {
    let path: String
    let commitId: String
    let size: Int
    let isText: Bool
    let content: String?
    /// Image files (png, jpeg, gif…) up to 10 MB.
    let imageBase64: String?
    let mimeType: String?

    var imageData: Data? { imageBase64.flatMap { Data(base64Encoded: $0) } }
}

/// One page of the quick file switcher's server-side search - `nextCursor`
/// is an opaque token (the backend's serialized remaining BFS queue) to
/// pass back for "Load More", `nil` once the whole tree has been walked.
struct CodeCommitFileSearchPage: Codable {
    let paths: [String]
    /// Matching folders (optional: older sidecars only sent files).
    let folders: [String]?
    let nextCursor: String?
}

struct CodeCommitCommit: Codable, Identifiable {
    var id: String { commitId }
    let commitId: String
    let shortId: String
    let message: String
    let authorName: String?
    let authorEmail: String?
    let date: String?
    let parents: [String]
}

/// One page of path-scoped history (`getCommitsForPath` in the backend) -
/// `nextCursor` is the commit ID to resume the walk from for "Load More",
/// `nil` once the branch's history has been fully walked.
struct CodeCommitPathHistoryPage: Codable {
    let commits: [CodeCommitCommit]
    let nextCursor: String?
}

struct CodeCommitPullRequest: Codable, Identifiable {
    var id: String { pullRequestId }
    let pullRequestId: String
    let title: String
    let description: String?
    let status: String
    let authorArn: String?
    let creationDate: String?
    let lastActivityDate: String?
    let sourceReference: String?
    let destinationReference: String?
    let sourceCommit: String?
    let destinationCommit: String?
    let mergeBase: String?
    let isMerged: Bool?
    let mergedBy: String?
    let mergeCommitId: String?
    let revisionId: String?
}

struct CodeCommitCommentLocation: Codable, Hashable {
    let filePath: String?
    let filePosition: Int?
    let relativeFileVersion: String?
}

struct CodeCommitComment: Codable, Identifiable, Hashable {
    var id: String { commentId }
    let commentId: String
    let content: String
    let inReplyTo: String?
    let creationDate: String?
    let authorArn: String?
    let deleted: Bool?
}

struct CodeCommitCommentThread: Codable, Identifiable {
    /// The root comment's id (stable across reloads, so lists don't redraw).
    var id: String { comments.first?.commentId ?? "\(location?.filePath ?? "")-\(location?.filePosition ?? 0)-\(afterCommitId ?? "")" }
    let location: CodeCommitCommentLocation?
    /// The comparison the thread was written on (nil from older sidecars).
    var beforeCommitId: String? = nil
    var afterCommitId: String? = nil
    let comments: [CodeCommitComment]

    /// The diff line an inline thread is anchored to (nil = whole file or general).
    var lineRef: DiffLineRef? {
        guard let line = location?.filePosition, location?.filePath != nil else { return nil }
        return DiffLineRef(side: location?.relativeFileVersion == DiffSide.before.rawValue ? .before : .after, line: line)
    }
}

struct CodeCommitApproval: Codable, Identifiable, Hashable {
    var id: String { userArn }
    let userArn: String
    let approvalState: String
}

struct CodeCommitPullRequestEvent: Codable, Identifiable {
    var id: String { "\(eventDate ?? "")-\(eventType ?? "")" }
    let eventDate: String?
    let eventType: String?
    let actorArn: String?
}

struct CodeCommitRepositoryTrigger: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var destinationArn: String
    var customData: String?
    var branches: [String]
    var events: [String]
}

enum CodeCommitMergeOption: String, Codable, CaseIterable, Identifiable {
    case fastForward = "FAST_FORWARD_MERGE"
    case squash = "SQUASH_MERGE"
    case threeWay = "THREE_WAY_MERGE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fastForward: "Fast forward merge"
        case .squash: "Squash merge"
        case .threeWay: "Three-way merge"
        }
    }
}

struct CodeCommitMergeCheck: Codable {
    let mergeable: Bool
    let destinationCommitId: String
    let sourceCommitId: String
    let conflictedFilePaths: [String]
}

struct CodeCommitPRLimits: Codable {
    let titleMaxLength: Int
    let descriptionMaxLength: Int
}

struct CodeCommitDiffEntry: Codable, Identifiable {
    var id: String { path }
    let changeType: String
    let path: String
    let beforeBlobId: String?
    let afterBlobId: String?
}

struct CodeCommitDiffLine: Codable, Identifiable {
    var id: String { UUID().uuidString }
    let type: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct CodeCommitDiffHunk: Codable, Identifiable {
    var id: String { header }
    let header: String
    let lines: [CodeCommitDiffLine]
}

struct CodeCommitFileDiff: Codable {
    let path: String
    let changeType: String
    let binary: Bool
    let additions: Int
    let deletions: Int
    let hunks: [CodeCommitDiffHunk]
}

// MARK: - Secrets Manager

struct SecretsManagerSecret: Codable, Identifiable {
    var id: String { arn }
    let name: String
    let arn: String
    let description: String?
    let lastChangedDate: String?
}

typealias SecretsManagerTag = ResourceTag

struct SecretsManagerVersionStage: Codable, Identifiable {
    var id: String { versionId }
    let versionId: String
    let stages: [String]
}

/// No field for the secret's actual value on purpose - `GetSecretValue` is
/// only ever called on demand (the "Reveal Secret Value" button), never
/// bundled into loading this detail automatically.
struct SecretsManagerSecretDetail: Codable {
    let name: String
    let arn: String
    let description: String?
    let kmsKeyId: String?
    let rotationEnabled: Bool?
    let rotationLambdaArn: String?
    let lastRotatedDate: String?
    let lastChangedDate: String?
    let lastAccessedDate: String?
    let deletedDate: String?
    let nextRotationDate: String?
    let createdDate: String?
    let tags: [SecretsManagerTag]
    let versionStages: [SecretsManagerVersionStage]
}

struct SecretsManagerSecretValue: Codable {
    let secretString: String?
    let secretBinary: String?
    let versionId: String?
}

struct SecretsManagerResourcePolicy: Codable {
    let policy: String?
}

// MARK: - CloudFormation

struct CloudFormationStack: Codable, Identifiable {
    var id: String { stackId }
    let stackName: String
    let stackId: String
    let status: String
    let creationTime: String?
    let lastUpdatedTime: String?
}

typealias CloudFormationTag = ResourceTag

struct CloudFormationOutput: Codable, Identifiable {
    var id: String { key }
    let key: String
    let value: String?
    let description: String?
    let exportName: String?
}

struct CloudFormationParameter: Codable, Identifiable {
    var id: String { key }
    let key: String
    let value: String?
}

struct CloudFormationStackDetail: Codable {
    let stackName: String
    let stackId: String
    let status: String
    let statusReason: String?
    let description: String?
    let creationTime: String?
    let lastUpdatedTime: String?
    let roleArn: String?
    let enableTerminationProtection: Bool
    let driftStatus: String?
    let parameters: [CloudFormationParameter]
    let outputs: [CloudFormationOutput]
    let tags: [CloudFormationTag]
}

struct CloudFormationStackEvent: Codable, Identifiable {
    var id: String { eventId }
    let eventId: String
    let logicalResourceId: String?
    let physicalResourceId: String?
    let resourceType: String?
    let resourceStatus: String?
    let resourceStatusReason: String?
    let timestamp: String?
}

struct CloudFormationStackResource: Codable, Identifiable {
    var id: String { logicalResourceId }
    let logicalResourceId: String
    let physicalResourceId: String?
    let resourceType: String
    let resourceStatus: String
    let resourceStatusReason: String?
}

// MARK: - Elastic Load Balancing

struct LoadBalancer: Codable, Identifiable {
    var id: String { loadBalancerArn }
    let loadBalancerArn: String
    let loadBalancerName: String
    let dnsName: String?
    let type: String?
    let scheme: String?
    let state: String?
    let vpcId: String?
    let createdTime: String?
}

// MARK: - API Gateway

// MARK: - API Gateway v2 (HTTP + WebSocket APIs)

struct HttpApi: Codable, Identifiable, Hashable {
    var id: String { apiId }
    let apiId: String
    let name: String
    /// "HTTP" or "WEBSOCKET".
    let protocolType: String
    let apiEndpoint: String?
    let description: String?
    let createdDate: String?
}

struct HttpApiRoute: Codable, Identifiable, Hashable {
    var id: String { routeId }
    let routeId: String
    let routeKey: String
    let authorizationType: String?
    let authorizerId: String?
    let authorizationScopes: [String]
    let integrationId: String?
    let apiKeyRequired: Bool?

    /// "GET /items" -> ("GET", "/items"); "$default" -> (nil, "$default").
    var method: String? { routeKey.contains(" ") ? String(routeKey.split(separator: " ", maxSplits: 1)[0]) : nil }
    var path: String { routeKey.contains(" ") ? String(routeKey.split(separator: " ", maxSplits: 1)[1]) : routeKey }
}

struct HttpApiIntegration: Codable, Identifiable, Hashable {
    var id: String { integrationId }
    let integrationId: String
    let integrationType: String
    let integrationMethod: String?
    let target: String?
    let connectionType: String?
    let payloadFormatVersion: String?
    let timeoutInMillis: Int?
    let description: String?
}

struct HttpApiStage: Codable, Identifiable, Hashable {
    var id: String { stageName }
    let stageName: String
    let autoDeploy: Bool
    let deploymentId: String?
    let description: String?
    let createdDate: String?
    let lastUpdatedDate: String?
    let lastDeploymentStatusMessage: String?
    let throttlingBurstLimit: Int?
    let throttlingRateLimit: Double?
    let detailedMetricsEnabled: Bool?
    let accessLogDestination: String?
    let stageVariables: [ResourceTag]
    let invokeUrl: String?
}

struct HttpApiAuthorizer: Codable, Identifiable, Hashable {
    var id: String { authorizerId }
    let authorizerId: String
    let name: String
    let authorizerType: String
    let identitySource: [String]
    let issuer: String?
    let audience: [String]
    let authorizerUri: String?
    let payloadFormatVersion: String?
    let enableSimpleResponses: Bool?
    let resultTtlInSeconds: Int?
}

struct HttpApiCors: Codable, Hashable {
    let allowOrigins: [String]
    let allowMethods: [String]
    let allowHeaders: [String]
    let exposeHeaders: [String]
    let allowCredentials: Bool
    let maxAge: Int?
}

struct HttpApiDetail: Codable {
    let apiId: String
    let name: String
    let protocolType: String
    let apiEndpoint: String?
    let description: String?
    let createdDate: String?
    let disableExecuteApiEndpoint: Bool
    let routeSelectionExpression: String?
    let apiKeySelectionExpression: String?
    let version: String?
    let arn: String
    let cors: HttpApiCors?
    let tags: [ResourceTag]
    let routes: [HttpApiRoute]
    let integrations: [HttpApiIntegration]
    let stages: [HttpApiStage]
    let authorizers: [HttpApiAuthorizer]

    var isWebSocket: Bool { protocolType == "WEBSOCKET" }
}

struct RestApi: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let createdDate: String?
    let endpointType: String?
}

struct ApiGatewayMethod: Codable, Identifiable, Hashable {
    var id: String { httpMethod }
    let httpMethod: String
    let authorizationType: String?
    let apiKeyRequired: Bool?
    let integrationType: String?
    let integrationUri: String?
}

struct ApiGatewayResource: Codable, Identifiable {
    let id: String
    let parentId: String?
    let pathPart: String?
    let path: String
    let methods: [ApiGatewayMethod]
}

struct ApiGatewayStageVariable: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
}

struct ApiGatewayStage: Codable, Identifiable {
    var id: String { stageName }
    let stageName: String
    let deploymentId: String?
    let description: String?
    let lastUpdatedDate: String?
    let variables: [ApiGatewayStageVariable]
}

// MARK: - SNS

struct SnsTopic: Codable, Identifiable {
    var id: String { topicArn }
    let topicArn: String
    let name: String
}

// MARK: - ECR

struct EcrRepository: Codable, Identifiable {
    var id: String { repositoryName }
    let repositoryName: String
    let repositoryUri: String?
    let createdAt: String?
    let imageTagMutability: String?
}

// MARK: - KMS

struct KmsKey: Codable, Identifiable {
    var id: String { keyId }
    let keyId: String
    let keyArn: String
}

typealias KmsTag = ResourceTag

struct KmsKeyDetail: Codable {
    let keyId: String
    let keyArn: String
    let description: String?
    let keyUsage: String?
    let keySpec: String?
    let origin: String?
    let keyManager: String?
    let keyState: String?
    let enabled: Bool
    let multiRegion: Bool?
    let creationDate: String?
    let deletionDate: String?
    let rotationEnabled: Bool?
    let rotationSupported: Bool
    let aliases: [String]
    let tags: [KmsTag]
    var rotationPeriodInDays: Int?
    var nextRotationDate: String?
    var encryptionAlgorithms: [String]?
    var signingAlgorithms: [String]?
    var macAlgorithms: [String]?
    var pendingDeletionWindowInDays: Int?
}

// MARK: - Shared resource tag (ECS, RDS, Route53, ELB, SNS, ECR)

/// The one key/value tag shape every service uses (the per-service
/// `XxxTag` names are aliases of it), so `ResourceTagsEditor` serves all.
struct ResourceTag: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
}

// MARK: - ECS (service drill-down)

struct EcsServiceSummary: Codable, Identifiable, Hashable {
    var id: String { serviceArn }
    let serviceName: String
    let serviceArn: String
    let status: String
    let desiredCount: Int
    let runningCount: Int
    let pendingCount: Int
    let launchType: String?
    let taskDefinition: String
}

struct EcsServiceEvent: Codable, Identifiable {
    let id: String
    let createdAt: String?
    let message: String
}

struct EcsDeployment: Codable, Identifiable {
    let id: String
    let status: String
    let taskDefinition: String
    let desiredCount: Int
    let runningCount: Int
    let pendingCount: Int
    let failedTasks: Int
    let rolloutState: String?
    let rolloutStateReason: String?
    let createdAt: String?
    let updatedAt: String?
}

struct EcsLoadBalancerRef: Codable, Hashable {
    let targetGroupArn: String?
    let loadBalancerName: String?
    let containerName: String?
    let containerPort: Int?
}

struct EcsServiceDetail: Codable {
    let serviceName: String
    let serviceArn: String
    let status: String
    let desiredCount: Int
    let runningCount: Int
    let pendingCount: Int
    let launchType: String?
    let taskDefinition: String
    let clusterArn: String
    let platformVersion: String?
    let schedulingStrategy: String?
    let createdAt: String?
    let createdBy: String?
    let minimumHealthyPercent: Int?
    let maximumPercent: Int?
    let circuitBreakerEnabled: Bool?
    let circuitBreakerRollback: Bool?
    let subnets: [String]
    let securityGroups: [String]
    let assignPublicIp: String?
    let loadBalancers: [EcsLoadBalancerRef]
    let capacityProviders: [String]
    let deployments: [EcsDeployment]
    let events: [EcsServiceEvent]
    let tags: [ResourceTag]
}

struct EcsContainerSummary: Codable, Hashable {
    let name: String
    let image: String?
    let lastStatus: String?
    let healthStatus: String?
    let exitCode: Int?
    let reason: String?
}

struct EcsTask: Codable, Identifiable {
    var id: String { taskArn }
    let taskArn: String
    let taskId: String
    let lastStatus: String?
    let desiredStatus: String?
    let healthStatus: String?
    let launchType: String?
    let cpu: String?
    let memory: String?
    let taskDefinition: String?
    let availabilityZone: String?
    let privateIp: String?
    let startedAt: String?
    let stoppedAt: String?
    let stoppedReason: String?
    let containers: [EcsContainerSummary]
}

struct EcsContainerDefinition: Codable, Identifiable {
    var id: String { name }
    let name: String
    let image: String?
    let cpu: Int?
    let memory: Int?
    let memoryReservation: Int?
    let essential: Bool?
    let portMappings: [String]
    let environmentCount: Int
    let secretsCount: Int
    let logGroup: String?
}

struct EcsTaskDefinitionSummary: Codable {
    let taskDefinitionArn: String
    let family: String
    let revision: Int
    let cpu: String?
    let memory: String?
    let networkMode: String?
    let requiresCompatibilities: [String]
    let taskRoleArn: String?
    let executionRoleArn: String?
    let registeredAt: String?
    let containers: [EcsContainerDefinition]
}

// MARK: - RDS (instance detail)

struct RdsInstanceDetail: Codable {
    let dbInstanceId: String
    let dbInstanceArn: String
    let dbInstanceClass: String
    let engine: String
    let engineVersion: String
    let status: String
    let endpoint: String?
    let port: Int?
    let availabilityZone: String?
    let secondaryAvailabilityZone: String?
    let multiAZ: Bool
    let publiclyAccessible: Bool
    let vpcId: String?
    let subnetGroupName: String?
    let subnets: [String]
    let securityGroups: [String]
    let caCertificateIdentifier: String?
    let storageType: String
    let allocatedStorage: Int
    let maxAllocatedStorage: Int?
    let iops: Int?
    let storageEncrypted: Bool
    let kmsKeyId: String?
    let masterUsername: String?
    let dbName: String?
    let parameterGroups: [String]
    let optionGroups: [String]
    let backupRetentionPeriod: Int
    let preferredBackupWindow: String?
    let preferredMaintenanceWindow: String?
    let latestRestorableTime: String?
    let autoMinorVersionUpgrade: Bool
    let deletionProtection: Bool
    let performanceInsightsEnabled: Bool
    let iamAuthEnabled: Bool
    let dbClusterIdentifier: String?
    let createdAt: String?
    let pendingModifiedValues: [String]
    let tags: [ResourceTag]
}

struct RdsEvent: Codable, Identifiable {
    var id: String { (date ?? "") + message }
    let date: String?
    let message: String
    let categories: [String]
}

struct RdsLogFile: Codable, Identifiable, Hashable {
    var id: String { logFileName }
    let logFileName: String
    let lastWritten: String?
    let size: Int
}

struct RdsLogContent: Codable {
    let logFileName: String
    let content: String
    let truncated: Bool
}

struct RdsSnapshot: Codable, Identifiable {
    var id: String { snapshotId }
    let snapshotId: String
    let snapshotType: String?
    let status: String?
    let createdAt: String?
    let allocatedStorage: Int?
    let engine: String?
    let engineVersion: String?
    let percentProgress: Int?
}

struct RdsMetricsSummary: Codable {
    let cpuUtilizationAverage: Double?
    let cpuUtilizationMax: Double?
    let databaseConnectionsAverage: Double?
    let databaseConnectionsMax: Double?
    let freeStorageSpaceMin: Double?
    let freeableMemoryMin: Double?
    let readIopsAverage: Double?
    let writeIopsAverage: Double?
}

// MARK: - Route53 (zone detail)

struct Route53ZoneDetail: Codable {
    let id: String
    let name: String
    let isPrivate: Bool
    let comment: String?
    let recordCount: Int
    let nameServers: [String]
    let vpcs: [String]
    let tags: [ResourceTag]
}

struct Route53AliasTarget: Codable, Hashable {
    let dnsName: String
    let hostedZoneId: String
    let evaluateTargetHealth: Bool
}

struct Route53Record: Codable, Identifiable, Hashable {
    var id: String { "\(name)|\(type)|\(setIdentifier ?? "")" }
    let name: String
    let type: String
    let ttl: Int?
    let values: [String]
    let aliasTarget: Route53AliasTarget?
    let setIdentifier: String?
    let weight: Int?
    let region: String?
    let failover: String?
    let healthCheckId: String?

    /// Routing-policy summary for the records table ("Simple", "Weighted 10", ...).
    var routingPolicy: String {
        if let weight { return "Weighted \(weight)" }
        if let failover { return "Failover \(failover.lowercased())" }
        if let region { return "Latency \(region)" }
        return "Simple"
    }
}

struct Route53RecordPage: Codable {
    let records: [Route53Record]
    let nextRecordName: String?
    let nextRecordType: String?
    let nextRecordIdentifier: String?
}

// MARK: - ELB (load balancer detail)

struct LoadBalancerDetail: Codable {
    let loadBalancerArn: String
    let loadBalancerName: String
    let dnsName: String?
    let canonicalHostedZoneId: String?
    let type: String?
    let scheme: String?
    let state: String?
    let stateReason: String?
    let vpcId: String?
    let ipAddressType: String?
    let createdTime: String?
    let availabilityZones: [String]
    let securityGroups: [String]
    let deletionProtection: Bool
    let attributes: [ResourceTag]
    let tags: [ResourceTag]
}

struct ElbRule: Codable, Identifiable {
    var id: String { ruleArn }
    let ruleArn: String
    let priority: String
    let isDefault: Bool
    let conditions: [String]
    let actions: [String]
}

struct ElbListener: Codable, Identifiable {
    var id: String { listenerArn }
    let listenerArn: String
    let `protocol`: String?
    let port: Int?
    let sslPolicy: String?
    let certificates: [String]
    let defaultActions: [String]
    let rules: [ElbRule]
}

struct ElbTargetHealth: Codable, Identifiable {
    var id: String { "\(targetId):\(port ?? 0)" }
    let targetId: String
    let port: Int?
    let availabilityZone: String?
    let state: String?
    let reason: String?
    let description: String?
}

struct ElbTargetGroup: Codable, Identifiable {
    var id: String { targetGroupArn }
    let targetGroupArn: String
    let targetGroupName: String
    let `protocol`: String?
    let port: Int?
    let targetType: String?
    let healthCheckProtocol: String?
    let healthCheckPort: String?
    let healthCheckPath: String?
    let healthCheckIntervalSeconds: Int?
    let healthCheckTimeoutSeconds: Int?
    let healthyThresholdCount: Int?
    let unhealthyThresholdCount: Int?
    let matcher: String?
    let targets: [ElbTargetHealth]
}

// MARK: - SNS (topic detail)

struct SnsTopicDetail: Codable {
    let topicArn: String
    let name: String
    let displayName: String?
    let owner: String?
    let subscriptionsConfirmed: Int
    let subscriptionsPending: Int
    let subscriptionsDeleted: Int
    let kmsMasterKeyId: String?
    let fifoTopic: Bool
    let contentBasedDeduplication: Bool
    let tags: [ResourceTag]
}

struct SnsSubscription: Codable, Identifiable {
    var id: String { pendingConfirmation ? "pending:\(self.protocol):\(endpoint)" : subscriptionArn }
    let subscriptionArn: String
    let `protocol`: String
    let endpoint: String
    let owner: String?
    let pendingConfirmation: Bool
}

/// `{ policy?: string }` - shared by every "maybe there's no policy yet" GET
/// (SNS access/delivery policy, ECR lifecycle and repository policy).
struct OptionalPolicyResponse: Codable {
    let policy: String?
}

// MARK: - ECR (repository detail)

struct EcrRepositoryDetail: Codable {
    let repositoryName: String
    let repositoryArn: String
    let repositoryUri: String
    let registryId: String
    let createdAt: String?
    let imageTagMutability: String?
    let scanOnPush: Bool
    let encryptionType: String?
    let kmsKey: String?
    let tags: [ResourceTag]
}

struct EcrImage: Codable, Identifiable {
    var id: String { imageDigest }
    let imageDigest: String
    let imageTags: [String]
    let pushedAt: String?
    let sizeInBytes: Int?
    let lastPulledAt: String?
    let mediaType: String?
    let scanStatus: String?
    let findingCounts: [ResourceTag]
}

struct EcrImagePage: Codable {
    let images: [EcrImage]
    let nextToken: String?
}

struct EcrScanFinding: Codable, Identifiable {
    var id: String { "\(name)|\(packageName ?? "")|\(packageVersion ?? "")" }
    let name: String
    let severity: String
    let description: String?
    let uri: String?
    let packageName: String?
    let packageVersion: String?
}

struct EcrScanFindings: Codable {
    let scanStatus: String?
    let scanStatusDescription: String?
    let completedAt: String?
    let findings: [EcrScanFinding]
}

// MARK: - App Config

/// One AWS access portal (IAM Identity Center start URL). `id` is its
/// `[sso-session]` name in ~/.aws/config.
struct SsoPlatformConfig: Codable, Equatable, Identifiable, Hashable {
    let id: String
    var name: String
    var startUrl: String
    var region: String
}

struct AwsConfigSection: Codable, Equatable {
    var platforms: [SsoPlatformConfig]
    var defaultRegion: String
}

/// A platform plus whether its SSO token in ~/.aws/sso/cache is still valid.
struct SsoPlatformStatus: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let startUrl: String
    let region: String
    let loggedIn: Bool
    let expiresAt: String?
    let profileCount: Int
}

struct KnownSsoSession: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let startUrl: String
    let region: String?
}

/// A profile signed in directly to an AWS account (outside IAM Identity
/// Center): `login` = `aws login` console credentials, `keys` = IAM access keys.
struct PersonalAccount: Codable, Identifiable, Hashable {
    var id: String { profile }
    let profile: String
    let kind: String
    let region: String?
}

struct PersonalAccountsState: Codable {
    let cliVersion: String?
    let awsLoginSupported: Bool
    let accounts: [PersonalAccount]
}

struct PersonalAccountResult: Codable {
    let profile: String
    let identity: CallerIdentity?
    let warning: String?
}

struct SetupState: Codable {
    let configPersisted: Bool
    let platforms: [SsoPlatformStatus]
    let knownSessions: [KnownSsoSession]
    let awsCliAvailable: Bool
}

struct AddPlatformResponse: Codable {
    let platformId: String
    let createdSsoSession: Bool
    let platforms: [SsoPlatformStatus]
}

struct PlatformsResponse: Codable {
    let platforms: [SsoPlatformStatus]
}

struct PersistResponse: Codable {
    let configPersisted: Bool
}

struct AppConfig: Codable {
    let app: AppConfigApp
    var aws: AwsConfigSection
    let selectedServices: [String]
    let maxTabs: Int
    let terminalPanelEnabled: Bool
    let kiroCliPanelEnabled: Bool
    let devTools: DevToolsConfig?
    let dynamoDbAutoColumnWidth: Bool
    /// Optional so a config served by an older sidecar still decodes.
    let dynamoDbItemView: String?
    let codeTheme: String?
    let layoutMode: String?
    let wordWrap: Bool?
    let fileIconTheme: String?
    let historyLayout: String?
    /// Optional: older sidecars don't send it.
    let dashboard: DashboardPrefs?
    let buttonColors: ButtonColorConfig
    let defaultIdeBundleIdentifier: String
}

struct AppConfigApp: Codable {
    let name: String
    let version: String
    let port: Int
}

struct RawConfigFileResponse: Decodable {
    let text: String
}
