import type { ResourceTag } from './index.js';

// ---- EC2 Auto Scaling ----

export interface AsgLaunchSource {
  /** "Launch template" / "Launch configuration" / "Mixed instances". */
  kind: string;
  name?: string;
  id?: string;
  version?: string;
}

export interface AsgSummary {
  name: string;
  arn: string;
  desiredCapacity: number;
  minSize: number;
  maxSize: number;
  instanceCount: number;
  healthyCount: number;
  status?: string;
  launchSource: AsgLaunchSource;
  availabilityZones: string[];
  createdTime?: string;
}

export interface AsgInstance {
  instanceId: string;
  instanceType?: string;
  availabilityZone?: string;
  lifecycleState?: string;
  healthStatus?: string;
  launchSource?: string;
  protectedFromScaleIn: boolean;
}

export interface AsgTag {
  key: string;
  value: string;
  propagateAtLaunch: boolean;
}

export interface AsgDetail extends AsgSummary {
  subnetIds: string[];
  healthCheckType?: string;
  healthCheckGracePeriod?: number;
  defaultCooldown?: number;
  defaultInstanceWarmup?: number;
  terminationPolicies: string[];
  targetGroupArns: string[];
  loadBalancerNames: string[];
  capacityRebalance: boolean;
  maxInstanceLifetime?: number;
  newInstancesProtectedFromScaleIn: boolean;
  serviceLinkedRoleArn?: string;
  placementGroup?: string;
  suspendedProcesses: string[];
  enabledMetrics: string[];
  instanceTypeOverrides: string[];
  onDemandBaseCapacity?: number;
  onDemandPercentageAboveBase?: number;
  spotAllocationStrategy?: string;
  instances: AsgInstance[];
  asgTags: AsgTag[];
  tags: ResourceTag[];
}

export interface AsgScalingPolicy {
  name: string;
  arn: string;
  policyType?: string;
  adjustmentType?: string;
  scalingAdjustment?: number;
  cooldown?: number;
  enabled: boolean;
  /** Target tracking: "ASGAverageCPUUtilization = 50" or the customized metric name. */
  targetTracking?: string;
  disableScaleIn?: boolean;
  stepAdjustments: string[];
  alarms: string[];
}

export interface AsgScheduledAction {
  name: string;
  recurrence?: string;
  startTime?: string;
  endTime?: string;
  minSize?: number;
  maxSize?: number;
  desiredCapacity?: number;
  timeZone?: string;
}

export interface AsgScaling {
  policies: AsgScalingPolicy[];
  scheduledActions: AsgScheduledAction[];
}

export interface AsgActivity {
  activityId: string;
  description?: string;
  cause?: string;
  statusCode?: string;
  statusMessage?: string;
  startTime?: string;
  endTime?: string;
  progress?: number;
}

export interface AsgInstanceRefresh {
  instanceRefreshId: string;
  status?: string;
  statusReason?: string;
  startTime?: string;
  endTime?: string;
  percentageComplete?: number;
  instancesToUpdate?: number;
}

export interface AsgActivityPage {
  activities: AsgActivity[];
  instanceRefreshes: AsgInstanceRefresh[];
}

// ---- Batch ----

export interface BatchJobQueue {
  jobQueueName: string;
  jobQueueArn: string;
  state?: string;
  status?: string;
  statusReason?: string;
  priority?: number;
  computeEnvironments: string[];
  schedulingPolicyArn?: string;
  tags: ResourceTag[];
}

export interface BatchComputeEnvironment {
  computeEnvironmentName: string;
  computeEnvironmentArn: string;
  type?: string;
  state?: string;
  status?: string;
  statusReason?: string;
  /** EC2 / SPOT / FARGATE / FARGATE_SPOT. */
  resourceType?: string;
  minvCpus?: number;
  maxvCpus?: number;
  desiredvCpus?: number;
  instanceTypes: string[];
  allocationStrategy?: string;
  subnets: string[];
  securityGroupIds: string[];
  instanceRole?: string;
  launchTemplate?: string;
  serviceRole?: string;
  ecsClusterArn?: string;
  eksClusterArn?: string;
  tags: ResourceTag[];
}

export interface BatchJobDefinition {
  jobDefinitionName: string;
  jobDefinitionArn: string;
  revision: number;
  type?: string;
  status?: string;
  platformCapabilities: string[];
  image?: string;
  vcpus?: string;
  memory?: string;
  timeoutSeconds?: number;
  retryAttempts?: number;
  propagateTags?: boolean;
  /** Pretty JSON of containerProperties / nodeProperties / eksProperties. */
  propertiesJson?: string;
  parameters: ResourceTag[];
  tags: ResourceTag[];
}

export interface BatchOverview {
  jobQueues: BatchJobQueue[];
  computeEnvironments: BatchComputeEnvironment[];
  jobDefinitions: BatchJobDefinition[];
}

export interface BatchJobSummary {
  jobId: string;
  jobName: string;
  status?: string;
  statusReason?: string;
  createdAt?: string;
  startedAt?: string;
  stoppedAt?: string;
  exitCode?: number;
  jobDefinition?: string;
  arraySize?: number;
}

export interface BatchJobDetail extends BatchJobSummary {
  jobArn?: string;
  jobQueue?: string;
  attempts: number;
  image?: string;
  command: string[];
  vcpus?: string;
  memory?: string;
  logStreamName?: string;
  reason?: string;
  dependsOn: string[];
  environment: ResourceTag[];
  tags: ResourceTag[];
}

// ---- Lightsail ----

export interface LightsailDisk {
  name: string;
  sizeInGb?: number;
  path?: string;
  isSystemDisk: boolean;
  iops?: number;
  state?: string;
}

export interface LightsailPort {
  fromPort?: number;
  toPort?: number;
  protocol?: string;
  state?: string;
  cidrs: string[];
}

export interface LightsailSnapshot {
  name: string;
  state?: string;
  sizeInGb?: number;
  createdAt?: string;
}

export interface LightsailInstance {
  name: string;
  arn: string;
  blueprintName?: string;
  bundleId?: string;
  state?: string;
  publicIp?: string;
  privateIp?: string;
  isStaticIp: boolean;
  availabilityZone?: string;
  createdAt?: string;
}

export interface LightsailInstanceDetail extends LightsailInstance {
  blueprintId?: string;
  cpuCount?: number;
  ramSizeInGb?: number;
  ipv6Addresses: string[];
  ipAddressType?: string;
  username?: string;
  sshKeyName?: string;
  monthlyTransferGb?: number;
  autoSnapshot?: string;
  disks: LightsailDisk[];
  ports: LightsailPort[];
  snapshots: LightsailSnapshot[];
  tags: ResourceTag[];
}

export interface LightsailDatabase {
  name: string;
  arn: string;
  engine?: string;
  engineVersion?: string;
  state?: string;
  masterUsername?: string;
  masterDatabaseName?: string;
  endpoint?: string;
  bundleId?: string;
  availabilityZone?: string;
  backupRetentionEnabled: boolean;
  publiclyAccessible: boolean;
  preferredBackupWindow?: string;
  preferredMaintenanceWindow?: string;
  createdAt?: string;
  tags: ResourceTag[];
}

export interface LightsailContainerService {
  name: string;
  arn: string;
  state?: string;
  power?: string;
  scale?: number;
  url?: string;
  isDisabled: boolean;
  privateDomainName?: string;
  containers: string[];
  createdAt?: string;
  tags: ResourceTag[];
}

// ---- Serverless Application Repository ----

export interface SarApplication {
  applicationId: string;
  name: string;
  author?: string;
  description?: string;
  creationTime?: string;
  homePageUrl?: string;
  labels: string[];
  spdxLicenseId?: string;
}

export interface SarParameter {
  name: string;
  type?: string;
  defaultValue?: string;
  description?: string;
  allowedValues: string[];
}

export interface SarVersion {
  semanticVersion: string;
  creationTime?: string;
  sourceCodeUrl?: string;
}

export interface SarPolicyStatement {
  statementId?: string;
  principals: string[];
  actions: string[];
}

export interface SarApplicationDetail extends SarApplication {
  isVerifiedAuthor: boolean;
  verifiedAuthorUrl?: string;
  licenseUrl?: string;
  readmeUrl?: string;
  semanticVersion?: string;
  templateUrl?: string;
  sourceCodeUrl?: string;
  requiredCapabilities: string[];
  resourcesSupported?: boolean;
  parameters: SarParameter[];
  versions: SarVersion[];
  policy: SarPolicyStatement[];
  policyError?: string;
}

// ---- Outposts ----

export interface Outpost {
  outpostId: string;
  outpostArn: string;
  name: string;
  description?: string;
  siteId?: string;
  availabilityZone?: string;
  lifeCycleStatus?: string;
  supportedHardwareType?: string;
  ownerId?: string;
  tags: ResourceTag[];
}

export interface OutpostAsset {
  assetId: string;
  assetType?: string;
  rackId?: string;
  hostId?: string;
  state?: string;
}

export interface OutpostDetail extends Outpost {
  siteName?: string;
  siteDescription?: string;
  instanceTypes: string[];
  assets: OutpostAsset[];
  assetsError?: string;
}

// ---- Wavelength / Local Zones ----

export interface EdgeZone {
  zoneName: string;
  zoneId?: string;
  zoneType?: string;
  groupName: string;
  networkBorderGroup?: string;
  optInStatus?: string;
  parentZoneName?: string;
  state?: string;
}

export interface EdgeZoneSubnet {
  subnetId: string;
  vpcId?: string;
  cidrBlock?: string;
  availabilityZone?: string;
  availableIpAddressCount?: number;
  name?: string;
}

export interface EdgeCarrierGateway {
  carrierGatewayId: string;
  vpcId?: string;
  state?: string;
  name?: string;
}

export interface EdgeZoneGroupDetail {
  groupName: string;
  zones: EdgeZone[];
  subnets: EdgeZoneSubnet[];
  carrierGateways: EdgeCarrierGateway[];
}

// ---- Elastic Beanstalk (environment drill-down) ----

export interface EbStatusCodes {
  status2xx?: number;
  status3xx?: number;
  status4xx?: number;
  status5xx?: number;
}

export interface EbLatency {
  p999?: number;
  p99?: number;
  p95?: number;
  p90?: number;
  p75?: number;
  p50?: number;
  p10?: number;
}

export interface EbInstanceHealth {
  instanceId: string;
  healthStatus?: string;
  color?: string;
  causes: string[];
  launchedAt?: string;
  availabilityZone?: string;
  instanceType?: string;
  deploymentVersion?: string;
  deploymentStatus?: string;
  requestCount?: number;
  latencyP90?: number;
  cpuUser?: number;
  cpuIdle?: number;
  loadAverage1?: number;
}

export interface EbInstanceCounts {
  ok?: number;
  info?: number;
  warning?: number;
  degraded?: number;
  severe?: number;
  pending?: number;
  unknown?: number;
  noData?: number;
}

export interface EbEnvironmentHealth {
  /** false = basic health reporting; only color + instance ids are known. */
  enhanced: boolean;
  color?: string;
  healthStatus?: string;
  status?: string;
  causes: string[];
  refreshedAt?: string;
  requestCount?: number;
  durationSeconds?: number;
  statusCodes?: EbStatusCodes;
  latency?: EbLatency;
  instanceCounts?: EbInstanceCounts;
  instances: EbInstanceHealth[];
}

export interface EbEnvironmentResources {
  instances: string[];
  autoScalingGroups: string[];
  loadBalancers: string[];
  launchTemplates: string[];
  launchConfigurations: string[];
  queues: { name: string; url?: string }[];
  triggers: string[];
}

export interface EbConfigOption {
  namespace: string;
  optionName: string;
  value?: string;
  resourceName?: string;
}

export interface EbConfiguration {
  platformArn?: string;
  solutionStackName?: string;
  deploymentStatus?: string;
  dateUpdated?: string;
  options: EbConfigOption[];
}

export interface EbApplicationVersion {
  versionLabel: string;
  description?: string;
  status?: string;
  dateCreated?: string;
  dateUpdated?: string;
  sourceBundle?: string;
  sourceRepository?: string;
  deployedTo: string[];
}

export interface EbLogEntry {
  instanceId: string;
  sampleTimestamp?: string;
  url: string;
  /** Tail logs only: the text, capped. */
  content?: string;
  truncated?: boolean;
}

export interface EbManagedAction {
  actionId: string;
  actionType?: string;
  actionDescription?: string;
  status?: string;
  windowStartTime?: string;
}

export interface EbManagedActionHistoryItem {
  actionId: string;
  actionType?: string;
  actionDescription?: string;
  status?: string;
  failureType?: string;
  failureDescription?: string;
  executedTime?: string;
  finishedTime?: string;
}

export interface EbManagedUpdates {
  pending: EbManagedAction[];
  history: EbManagedActionHistoryItem[];
}
