import Foundation

// Models for EKS, Fargate and App Runner. Field names match
// packages/api/src/domain/entities/containers.ts.

// MARK: - EKS

struct EksClusterSummary: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let arn: String?
    let status: String?
    let version: String?
    let platformVersion: String?
    let createdAt: String?
}

struct EksClusterDetail: Codable {
    let name: String
    let arn: String?
    let status: String?
    let version: String?
    let platformVersion: String?
    let createdAt: String?
    let endpoint: String?
    let roleArn: String?
    let oidcIssuer: String?
    let certificateAuthority: Bool?
    let vpcId: String?
    let subnetIds: [String]
    let securityGroupIds: [String]
    let clusterSecurityGroupId: String?
    let endpointPublicAccess: Bool?
    let endpointPrivateAccess: Bool?
    let publicAccessCidrs: [String]
    let serviceIpv4Cidr: String?
    let ipFamily: String?
    let authenticationMode: String?
    let supportType: String?
    let enabledLogTypes: [String]
    let disabledLogTypes: [String]
    let secretsEncryptionKeyArn: String?
    let healthIssues: [String]
    let tags: [ResourceTag]
}

struct EksNodegroup: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let arn: String?
    let status: String?
    let capacityType: String?
    let amiType: String?
    let instanceTypes: [String]?
    let minSize: Int?
    let maxSize: Int?
    let desiredSize: Int?
    let version: String?
    let releaseVersion: String?
    let diskSize: Int?
    let nodeRole: String?
    let subnets: [String]?
    let launchTemplate: String?
    let labels: [ResourceTag]?
    let taints: [String]?
    let healthIssues: [String]?
    let autoScalingGroups: [String]?
    let createdAt: String?
}

struct EksFargateProfile: Codable, Identifiable, Hashable {
    var id: String { "\(clusterName ?? "")/\(name)" }
    let name: String
    let arn: String?
    let status: String?
    let podExecutionRoleArn: String?
    let subnets: [String]
    let selectors: [String]
    let createdAt: String?
    /// Only set in the Fargate overview.
    let clusterName: String?
}

struct EksAddon: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let version: String?
    let status: String?
    let serviceAccountRoleArn: String?
    let healthIssues: [String]
    let createdAt: String?
    let modifiedAt: String?
}

struct EksAccessEntry: Codable, Identifiable, Hashable {
    var id: String { principalArn }
    let principalArn: String
    let type: String?
    let username: String?
    let kubernetesGroups: [String]
    let createdAt: String?
}

struct EksUpdate: Codable, Identifiable, Hashable {
    let id: String
    let type: String?
    let status: String?
    let createdAt: String?
    let params: [String]
    let errors: [String]
}

struct EksCompute: Codable {
    let nodegroups: [EksNodegroup]
    let fargateProfiles: [EksFargateProfile]
}

// MARK: - Fargate

struct FargateTask: Codable, Identifiable, Hashable {
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
    let clusterName: String
    let clusterArn: String
    let group: String?
    let capacityProviderName: String?
    let platformVersion: String?
}

struct FargateOverview: Codable {
    let tasks: [FargateTask]
    let truncated: Bool
    let profiles: [EksFargateProfile]
    let errors: [String]
}

// MARK: - App Runner

struct AppRunnerServiceSummary: Codable, Identifiable, Hashable {
    var id: String { serviceArn }
    let serviceName: String
    let serviceArn: String
    let serviceId: String?
    let serviceUrl: String?
    let status: String?
    let createdAt: String?
    let updatedAt: String?
}

struct AppRunnerServiceDetail: Codable {
    let serviceName: String
    let serviceArn: String
    let serviceId: String?
    let serviceUrl: String?
    let status: String?
    let createdAt: String?
    let updatedAt: String?
    let sourceType: String?
    let imageIdentifier: String?
    let imageRepositoryType: String?
    let repositoryUrl: String?
    let branch: String?
    let autoDeploymentsEnabled: Bool?
    let port: String?
    let startCommand: String?
    let runtime: String?
    let buildCommand: String?
    let environmentVariables: [ResourceTag]
    let secretNames: [String]
    let cpu: String?
    let memory: String?
    let instanceRoleArn: String?
    let healthCheck: String?
    let autoScalingConfigurationName: String?
    let autoScalingConfigurationArn: String?
    let egressType: String?
    let vpcConnectorArn: String?
    let isPubliclyAccessible: Bool?
    let ipAddressType: String?
    let observabilityEnabled: Bool?
    let kmsKey: String?
    let tags: [ResourceTag]
}

struct AppRunnerOperation: Codable, Identifiable, Hashable {
    let id: String
    let type: String?
    let status: String?
    let startedAt: String?
    let endedAt: String?
}

struct AppRunnerCustomDomain: Codable, Identifiable, Hashable {
    var id: String { domainName }
    let domainName: String
    let status: String?
    let enableWWWSubdomain: Bool?
    let validationRecords: [String]
}

struct AppRunnerActivity: Codable {
    let operations: [AppRunnerOperation]
    let customDomains: [AppRunnerCustomDomain]
    let dnsTarget: String?
}
