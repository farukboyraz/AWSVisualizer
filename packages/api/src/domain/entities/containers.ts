import type { ResourceTag, EcsTask } from './index.js';

// ---- EKS ----

export interface EksClusterSummary {
  name: string;
  arn?: string;
  status?: string;
  version?: string;
  platformVersion?: string;
  createdAt?: string;
}

export interface EksClusterDetail extends EksClusterSummary {
  endpoint?: string;
  roleArn?: string;
  oidcIssuer?: string;
  certificateAuthority?: boolean;
  vpcId?: string;
  subnetIds: string[];
  securityGroupIds: string[];
  clusterSecurityGroupId?: string;
  endpointPublicAccess?: boolean;
  endpointPrivateAccess?: boolean;
  publicAccessCidrs: string[];
  serviceIpv4Cidr?: string;
  ipFamily?: string;
  authenticationMode?: string;
  supportType?: string;
  enabledLogTypes: string[];
  disabledLogTypes: string[];
  secretsEncryptionKeyArn?: string;
  healthIssues: string[];
  tags: ResourceTag[];
}

export interface EksNodegroup {
  name: string;
  arn?: string;
  status?: string;
  capacityType?: string;
  amiType?: string;
  instanceTypes: string[];
  minSize?: number;
  maxSize?: number;
  desiredSize?: number;
  version?: string;
  releaseVersion?: string;
  diskSize?: number;
  nodeRole?: string;
  subnets: string[];
  launchTemplate?: string;
  labels: ResourceTag[];
  taints: string[];
  healthIssues: string[];
  autoScalingGroups: string[];
  createdAt?: string;
}

export interface EksFargateProfile {
  name: string;
  arn?: string;
  status?: string;
  podExecutionRoleArn?: string;
  subnets: string[];
  /** "namespace" or "namespace {label=value}". */
  selectors: string[];
  createdAt?: string;
}

export interface EksAddon {
  name: string;
  version?: string;
  status?: string;
  serviceAccountRoleArn?: string;
  healthIssues: string[];
  createdAt?: string;
  modifiedAt?: string;
}

export interface EksAccessEntry {
  principalArn: string;
  type?: string;
  username?: string;
  kubernetesGroups: string[];
  createdAt?: string;
}

export interface EksUpdate {
  id: string;
  type?: string;
  status?: string;
  createdAt?: string;
  params: string[];
  errors: string[];
}

export interface EksCompute {
  nodegroups: EksNodegroup[];
  fargateProfiles: EksFargateProfile[];
}

// ---- Fargate ----

export interface FargateTask extends EcsTask {
  clusterName: string;
  clusterArn: string;
  group?: string;
  capacityProviderName?: string;
  platformVersion?: string;
}

export interface FargateOverview {
  tasks: FargateTask[];
  /** True when the per-cluster task walk hit its cap. */
  truncated: boolean;
  profiles: (EksFargateProfile & { clusterName: string })[];
  errors: string[];
}

// ---- App Runner ----

export interface AppRunnerServiceSummary {
  serviceName: string;
  serviceArn: string;
  serviceId?: string;
  serviceUrl?: string;
  status?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface AppRunnerServiceDetail extends AppRunnerServiceSummary {
  sourceType?: string;
  imageIdentifier?: string;
  imageRepositoryType?: string;
  repositoryUrl?: string;
  branch?: string;
  autoDeploymentsEnabled?: boolean;
  port?: string;
  startCommand?: string;
  runtime?: string;
  buildCommand?: string;
  environmentVariables: ResourceTag[];
  secretNames: string[];
  cpu?: string;
  memory?: string;
  instanceRoleArn?: string;
  healthCheck?: string;
  autoScalingConfigurationName?: string;
  autoScalingConfigurationArn?: string;
  egressType?: string;
  vpcConnectorArn?: string;
  isPubliclyAccessible?: boolean;
  ipAddressType?: string;
  observabilityEnabled?: boolean;
  kmsKey?: string;
  tags: ResourceTag[];
}

export interface AppRunnerOperation {
  id: string;
  type?: string;
  status?: string;
  startedAt?: string;
  endedAt?: string;
}

export interface AppRunnerCustomDomain {
  domainName: string;
  status?: string;
  enableWWWSubdomain?: boolean;
  validationRecords: string[];
}

export interface AppRunnerActivity {
  operations: AppRunnerOperation[];
  customDomains: AppRunnerCustomDomain[];
  dnsTarget?: string;
}
