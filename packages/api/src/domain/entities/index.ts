export interface Environment {
  environmentName: string;
  environmentId: string;
  applicationName: string;
  status: string;
  health: string;
  healthStatus?: string;
  solutionStackName?: string;
  platformArn?: string;
  versionLabel?: string;
  dateCreated?: string;
  dateUpdated?: string;
  endpointURL?: string;
  cname?: string;
  tier?: {
    name: string;
    type: string;
  };
}

export interface EbEnvironmentVariable {
  key: string;
  value: string;
}

export interface EbTag {
  key: string;
  value: string;
}

export interface EbEnvironmentDetail {
  environmentName: string;
  environmentId: string;
  environmentArn?: string;
  applicationName: string;
  status: string;
  health: string;
  healthStatus?: string;
  solutionStackName?: string;
  platformArn?: string;
  versionLabel?: string;
  dateCreated?: string;
  dateUpdated?: string;
  endpointURL?: string;
  cname?: string;
  tier?: {
    name: string;
    type: string;
  };
  environmentVariables: EbEnvironmentVariable[];
  tags: EbTag[];
}

export interface EbEvent {
  eventDate: string;
  message: string;
  applicationName: string;
  environmentName?: string;
  severity: string;
}

export interface CallerIdentity {
  account: string;
  arn: string;
  userId: string;
}

export interface DdbTableInfo {
  tableName: string;
  tableStatus: string;
  itemCount: number;
  tableSizeBytes: number;
  creationDateTime?: string;
  keySchema: {
    attributeName: string;
    keyType: string;
  }[];
  attributeDefinitions: {
    attributeName: string;
    attributeType: string;
  }[];
  /** GSIs and LSIs - what the Items tab's Query can target. */
  indexes: DdbIndexInfo[];
}

export interface DdbScanResult {
  items: Record<string, any>[];
  count: number;
  scannedCount: number;
  lastEvaluatedKey?: Record<string, any>;
}

/** One Filter Builder row, as the Swift `FilterCondition` sends it. */
export interface DdbFilterCondition {
  /** Absent on the first condition. */
  logicalOperator?: 'and' | 'or';
  columnID: string;
  matchOperator: 'equal' | 'notEqual' | 'contains' | 'onlyBNN' | 'notBNN' | 'in';
  values: string[];
}

export interface DdbSearchResult {
  items: Record<string, any>[];
  /** Items examined in this call (matched or not). */
  scannedCount: number;
  /**
   * Opaque resume token (per-segment scan positions of the parallel scan) -
   * pass it back as `cursor` to continue. Absent once every segment reached
   * the end of the table.
   */
  cursor?: string;
  /** How many parallel scan segments the search uses (informational). */
  totalSegments: number;
  /**
   * Set when the conditions pin a partition key and the search reads only
   * that partition with Query (`indexName` absent = the table's own key).
   */
  route?: { indexName?: string; attribute: string; value: string; sortKey?: { attribute: string; value: string } };
}

export interface S3Bucket {
  name: string;
  creationDate?: string;
  region?: string;
}

export interface S3Objects {
  prefix: string;
  objects: S3Object[];
  commonPrefixes: string[];
  isTruncated: boolean;
  nextContinuationToken?: string;
}

export interface S3Object {
  key: string;
  size: number;
  lastModified?: string;
  storageClass?: string;
}

export interface S3FilePreview {
  key: string;
  contentType: string;
  size: number;
  lastModified?: string;
  body?: string;
  isText: boolean;
  isTruncated: boolean;
}

export interface ZipEntry {
  path: string;
  isDirectory: boolean;
}

export interface ZipEntryList {
  entries: ZipEntry[];
}

export interface ZipEntryContent {
  path: string;
  content: string;
  isTruncated: boolean;
}

export interface LambdaFunction {
  functionName: string;
  runtime: string;
  handler: string;
  codeSize: number;
  memorySize: number;
  timeout: number;
  lastModified: string;
  state?: string;
  description?: string;
}

export interface LambdaTag {
  key: string;
  value: string;
}

export interface LambdaFunctionDetail {
  functionName: string;
  functionArn: string;
  runtime?: string;
  handler?: string;
  role?: string;
  codeSize: number;
  memorySize: number;
  timeout: number;
  lastModified: string;
  description?: string;
  state?: string;
  stateReason?: string;
  architectures?: string[];
  packageType?: string;
  environmentVariables: Record<string, string>;
  reservedConcurrentExecutions?: number;
  tags: LambdaTag[];
  codeLocation?: string;
}

export interface LambdaMetricsSummary {
  invocations: number;
  errors: number;
  throttles: number;
  averageDurationMs: number;
  logGroupName: string;
}

export interface LambdaVersion {
  version: string;
  lastModified: string;
  description?: string;
  codeSize: number;
}

export interface LambdaAlias {
  name: string;
  functionVersion: string;
  description?: string;
  aliasArn: string;
}

export interface LambdaEventSourceMapping {
  uuid: string;
  eventSourceArn?: string;
  functionArn?: string;
  state?: string;
  batchSize?: number;
  lastModified?: string;
  startingPosition?: string;
}

export interface LambdaInvokeResult {
  statusCode?: number;
  payload?: string;
  logResult?: string;
  functionError?: string;
  executedVersion?: string;
}

export interface Ec2Instance {
  instanceId: string;
  instanceType: string;
  state: string;
  name: string;
  privateIp?: string;
  publicIp?: string;
  launchTime?: string;
  platform?: string;
  availabilityZone?: string;
}

export interface Ec2SecurityGroupRef {
  groupId: string;
  groupName: string;
}

export interface Ec2Tag {
  key: string;
  value: string;
}

export interface Ec2InstanceDetail {
  instanceId: string;
  instanceType: string;
  state: string;
  name: string;
  privateIp?: string;
  publicIp?: string;
  launchTime?: string;
  platform?: string;
  availabilityZone?: string;
  imageId?: string;
  keyName?: string;
  vpcId?: string;
  subnetId?: string;
  rootDeviceType?: string;
  monitoringEnabled: boolean;
  disableApiTermination: boolean;
  iamInstanceProfileArn?: string;
  securityGroups: Ec2SecurityGroupRef[];
  tags: Ec2Tag[];
  architecture?: string;
  privateDnsName?: string;
  publicDnsName?: string;
  rootDeviceName?: string;
  ebsOptimized?: boolean;
  hostname?: string;
  blockDevices: Ec2BlockDevice[];
  networkInterfaces: Ec2NetworkInterface[];
}

export interface Ec2BlockDevice {
  deviceName: string;
  volumeId?: string;
  status?: string;
  attachTime?: string;
  deleteOnTermination: boolean;
}

export interface Ec2NetworkInterface {
  networkInterfaceId: string;
  description?: string;
  privateIp?: string;
  publicIp?: string;
  macAddress?: string;
  subnetId?: string;
  status?: string;
}

export interface Ec2KeyPair {
  keyName: string;
  keyPairId?: string;
}

export interface Ec2LaunchParams {
  imageId: string;
  instanceType: string;
  keyName?: string;
  securityGroupIds?: string[];
  subnetId?: string;
  name?: string;
}

export interface RdsInstance {
  dbInstanceId: string;
  dbInstanceClass: string;
  engine: string;
  engineVersion: string;
  status: string;
  endpoint?: string;
  port?: number;
  availabilityZone?: string;
  multiAZ: boolean;
  storageType: string;
  allocatedStorage: number;
}

export interface EcsCluster {
  clusterName: string;
  clusterArn: string;
  status: string;
  runningTasks: number;
  pendingTasks: number;
  activeServices: number;
  registeredContainerInstances: number;
}

export interface EcsService {
  serviceName: string;
  status: string;
  desiredCount: number;
  runningCount: number;
  pendingCount: number;
  launchType: string;
  taskDefinition: string;
}

export interface SqsQueue {
  queueUrl: string;
  queueName: string;
  approximateMessages: number;
  approximateMessagesNotVisible: number;
  approximateMessagesDelayed: number;
  visibilityTimeout: number;
}

export interface SqsTag {
  key: string;
  value: string;
}

export interface SqsQueueDetail {
  queueUrl: string;
  queueName: string;
  arn?: string;
  approximateMessages: number;
  approximateMessagesNotVisible: number;
  approximateMessagesDelayed: number;
  visibilityTimeout: number;
  messageRetentionPeriod: number;
  delaySeconds: number;
  receiveMessageWaitTimeSeconds: number;
  maximumMessageSize: number;
  fifoQueue: boolean;
  contentBasedDeduplication: boolean;
  kmsMasterKeyId?: string;
  createdTimestamp?: string;
  lastModifiedTimestamp?: string;
  tags: SqsTag[];
  /** Raw JSON access policy, if one is attached. */
  policy?: string;
  /** Parsed RedrivePolicy - where messages go after `maxReceiveCount` failed receives. */
  deadLetterTargetArn?: string;
  maxReceiveCount?: number;
  sqsManagedSseEnabled: boolean;
  kmsDataKeyReusePeriodSeconds?: number;
  fifoThroughputLimit?: string;
  deduplicationScope?: string;
}

export interface SqsMessage {
  messageId: string;
  receiptHandle: string;
  body: string;
  sentTimestamp?: string;
  approximateReceiveCount?: number;
}

export interface CloudWatchAlarm {
  alarmName: string;
  state: string;
  metricName: string;
  namespace: string;
  threshold?: number;
  comparisonOperator?: string;
}

export interface CloudWatchAlarmDimension {
  name: string;
  value: string;
}

export interface CloudWatchAlarmDetail {
  alarmName: string;
  alarmArn?: string;
  alarmDescription?: string;
  state: string;
  stateReason?: string;
  actionsEnabled: boolean;
  okActions: string[];
  alarmActions: string[];
  insufficientDataActions: string[];
  metricName: string;
  namespace: string;
  statistic?: string;
  extendedStatistic?: string;
  period?: number;
  evaluationPeriods?: number;
  datapointsToAlarm?: number;
  threshold?: number;
  comparisonOperator?: string;
  treatMissingData?: string;
  unit?: string;
  dimensions: CloudWatchAlarmDimension[];
}

export interface LogGroup {
  logGroupName: string;
  storedBytes: number;
  retentionInDays?: number;
  creationTime?: number;
}

export interface LogStreamInfo {
  logStreamName: string;
  creationTime?: number;
  firstEventTimestamp?: number;
  lastEventTimestamp?: number;
  storedBytes?: number;
}

export interface LogEventInfo {
  timestamp?: number;
  message?: string;
}

export interface CloudFrontDistribution {
  id: string;
  domainName: string;
  status: string;
  enabled: boolean;
  origins: string[];
  comment?: string;
  lastModified?: string;
  priceClass?: string;
}

export interface CloudFrontOrigin {
  id: string;
  domainName: string;
  originPath?: string;
  type: string;
}

export interface CloudFrontCacheBehavior {
  pathPattern: string;
  targetOriginId: string;
  viewerProtocolPolicy?: string;
  isDefault: boolean;
  allowedMethods?: string[];
  compress?: boolean;
  cachePolicyId?: string;
  originRequestPolicyId?: string;
}

export interface CloudFrontErrorResponse {
  errorCode: number;
  responsePagePath?: string;
  responseCode?: string;
  errorCachingMinTtl?: number;
}

export interface CloudFrontInvalidation {
  id: string;
  status: string;
  createTime?: string;
  paths?: string[];
}

export interface CloudFrontTag {
  key: string;
  value: string;
}

export interface CloudFrontDistributionDetail {
  id: string;
  arn?: string;
  domainName: string;
  status: string;
  enabled: boolean;
  comment?: string;
  lastModified?: string;
  priceClass?: string;
  origins: CloudFrontOrigin[];
  behaviors: CloudFrontCacheBehavior[];
  tags: CloudFrontTag[];
  aliases: string[];
  defaultRootObject?: string;
  httpVersion?: string;
  ipv6Enabled?: boolean;
  webAclId?: string;
  certificateSource?: string;
  certificateArn?: string;
  minimumProtocolVersion?: string;
  sslSupportMethod?: string;
  geoRestrictionType?: string;
  geoRestrictionLocations: string[];
  loggingBucket?: string;
  errorResponses: CloudFrontErrorResponse[];
}

export interface HostedZone {
  id: string;
  name: string;
  recordCount: number;
  isPrivate: boolean;
  comment?: string;
}

export interface CostSummary {
  totalCost: string;
  currency: string;
  period: { start: string; end: string };
  serviceBreakdown: { service: string; amount: string }[];
  /** Spend per day (granularity daily) or per month (monthly) of the period - named `daily` for older apps. */
  daily?: { date: string; amount: string }[];
  granularity?: 'daily' | 'monthly';
  /** Date of each `daily` point -> its services, largest first. */
  breakdown?: Record<string, { service: string; amount: string }[]>;
  view?: 'daily' | 'monthly' | 'month';
}

export interface CodeCommitRepository {
  repositoryName: string;
  repositoryId: string;
}

export interface CodeCommitRepositoryDetail {
  repositoryName: string;
  repositoryId: string;
  description?: string;
  defaultBranch?: string;
  cloneUrlHttp?: string;
  arn?: string;
  creationDate?: string;
  lastModifiedDate?: string;
  tags: CodeCommitTag[];
}

export interface CodeCommitTag {
  key: string;
  value: string;
}

export interface CodeCommitBranch {
  name: string;
  commitId?: string;
}

export interface CodeCommitFolderEntry {
  name: string;
  path: string;
  isFolder: boolean;
}

export interface CodeCommitFolderListing {
  path: string;
  commitId: string;
  entries: CodeCommitFolderEntry[];
}

export interface CodeCommitFileContent {
  path: string;
  commitId: string;
  size: number;
  isText: boolean;
  content?: string;
  /** Image files (png, jpeg, gif…) up to 10 MB, for the preview. */
  imageBase64?: string;
  mimeType?: string;
}

export interface CodeCommitCommit {
  commitId: string;
  shortId: string;
  message: string;
  authorName?: string;
  authorEmail?: string;
  date?: string;
  parents: string[];
}

export interface CodeCommitPullRequest {
  pullRequestId: string;
  title: string;
  description?: string;
  status: string;
  authorArn?: string;
  creationDate?: string;
  lastActivityDate?: string;
  sourceReference?: string;
  destinationReference?: string;
  sourceCommit?: string;
  destinationCommit?: string;
  mergeBase?: string;
  isMerged?: boolean;
  mergedBy?: string;
  mergeCommitId?: string;
  revisionId?: string;
}

export type CodeCommitMergeOption = 'FAST_FORWARD_MERGE' | 'SQUASH_MERGE' | 'THREE_WAY_MERGE';

export interface CodeCommitMergeCheck {
  mergeable: boolean;
  destinationCommitId: string;
  sourceCommitId: string;
  conflictedFilePaths: string[];
}

export interface CodeCommitCommentLocation {
  filePath?: string;
  filePosition?: number;
  relativeFileVersion?: string;
}

export interface CodeCommitComment {
  commentId: string;
  content: string;
  inReplyTo?: string;
  creationDate?: string;
  authorArn?: string;
  deleted?: boolean;
}

export interface CodeCommitCommentThread {
  location?: CodeCommitCommentLocation;
  /** The comparison the thread was written on; an inline thread whose
   *  afterCommitId is not the PR's current source commit is outdated. */
  beforeCommitId?: string;
  afterCommitId?: string;
  comments: CodeCommitComment[];
}

export interface CodeCommitApproval {
  userArn: string;
  approvalState: string;
}

export interface CodeCommitPullRequestEvent {
  eventDate?: string;
  eventType?: string;
  actorArn?: string;
}

export interface CodeCommitRepositoryTrigger {
  name: string;
  destinationArn: string;
  customData?: string;
  branches: string[];
  events: string[];
}

export interface CodeCommitDiffEntry {
  changeType: 'A' | 'M' | 'D';
  path: string;
  beforeBlobId?: string;
  afterBlobId?: string;
}

export interface CodeCommitDiffLine {
  type: 'add' | 'del' | 'context';
  text: string;
}

export interface CodeCommitDiffHunk {
  header: string;
  lines: CodeCommitDiffLine[];
}

export interface CodeCommitFileDiff {
  path: string;
  changeType: 'A' | 'M' | 'D';
  binary: boolean;
  additions: number;
  deletions: number;
  hunks: CodeCommitDiffHunk[];
}

export interface SecretsManagerSecret {
  name: string;
  arn: string;
  description?: string;
  lastChangedDate?: string;
}

export interface SecretsManagerTag {
  key: string;
  value: string;
}

export interface SecretsManagerVersionStage {
  versionId: string;
  stages: string[];
}

// Deliberately has no field for the secret's actual value - the list/detail
// endpoints never call GetSecretValue. The value is only ever fetched
// on-demand via a separate reveal endpoint (see SecretsManagerSecretValue),
// never bundled into this response automatically.
export interface SecretsManagerSecretDetail {
  name: string;
  arn: string;
  description?: string;
  kmsKeyId?: string;
  rotationEnabled?: boolean;
  rotationLambdaArn?: string;
  lastRotatedDate?: string;
  lastChangedDate?: string;
  lastAccessedDate?: string;
  deletedDate?: string;
  nextRotationDate?: string;
  createdDate?: string;
  tags: SecretsManagerTag[];
  versionStages: SecretsManagerVersionStage[];
}

export interface SecretsManagerResourcePolicy {
  policy?: string;
}

export interface SecretsManagerSecretValue {
  secretString?: string;
  /** Base64-encoded, only present when the secret was stored as binary. */
  secretBinary?: string;
  versionId?: string;
}

export interface CloudFormationStack {
  stackName: string;
  stackId: string;
  status: string;
  creationTime?: string;
  lastUpdatedTime?: string;
}

export interface CloudFormationTag {
  key: string;
  value: string;
}

export interface CloudFormationOutput {
  key: string;
  value?: string;
  description?: string;
  exportName?: string;
}

export interface CloudFormationParameter {
  key: string;
  value?: string;
}

export interface CloudFormationStackDetail {
  stackName: string;
  stackId: string;
  status: string;
  statusReason?: string;
  description?: string;
  creationTime?: string;
  lastUpdatedTime?: string;
  roleArn?: string;
  enableTerminationProtection: boolean;
  driftStatus?: string;
  parameters: CloudFormationParameter[];
  outputs: CloudFormationOutput[];
  tags: CloudFormationTag[];
}

export interface CloudFormationStackEvent {
  eventId: string;
  logicalResourceId?: string;
  physicalResourceId?: string;
  resourceType?: string;
  resourceStatus?: string;
  resourceStatusReason?: string;
  timestamp?: string;
}

export interface CloudFormationStackResource {
  logicalResourceId: string;
  physicalResourceId?: string;
  resourceType: string;
  resourceStatus: string;
  resourceStatusReason?: string;
}

export interface LoadBalancer {
  loadBalancerArn: string;
  loadBalancerName: string;
  dnsName?: string;
  type?: string;
  scheme?: string;
  state?: string;
  vpcId?: string;
  createdTime?: string;
}

export interface RestApi {
  id: string;
  name: string;
  description?: string;
  createdDate?: string;
  endpointType?: string;
}

// API Gateway v2 - HTTP and WebSocket APIs

export interface HttpApi {
  apiId: string;
  name: string;
  /** "HTTP" or "WEBSOCKET". */
  protocolType: string;
  apiEndpoint?: string;
  description?: string;
  createdDate?: string;
}

export interface HttpApiRoute {
  routeId: string;
  /** "GET /items/{id}", "ANY /{proxy+}", "$default", or a WebSocket route like "$connect". */
  routeKey: string;
  authorizationType?: string;
  authorizerId?: string;
  authorizationScopes: string[];
  integrationId?: string;
  apiKeyRequired?: boolean;
}

export interface HttpApiIntegration {
  integrationId: string;
  integrationType: string;
  integrationMethod?: string;
  target?: string;
  connectionType?: string;
  payloadFormatVersion?: string;
  timeoutInMillis?: number;
  description?: string;
}

export interface HttpApiStage {
  stageName: string;
  autoDeploy: boolean;
  deploymentId?: string;
  description?: string;
  createdDate?: string;
  lastUpdatedDate?: string;
  lastDeploymentStatusMessage?: string;
  throttlingBurstLimit?: number;
  throttlingRateLimit?: number;
  detailedMetricsEnabled?: boolean;
  accessLogDestination?: string;
  stageVariables: { key: string; value: string }[];
  invokeUrl?: string;
}

export interface HttpApiAuthorizer {
  authorizerId: string;
  name: string;
  /** "JWT" or "REQUEST" (Lambda). */
  authorizerType: string;
  identitySource: string[];
  issuer?: string;
  audience: string[];
  authorizerUri?: string;
  payloadFormatVersion?: string;
  enableSimpleResponses?: boolean;
  resultTtlInSeconds?: number;
}

export interface HttpApiCors {
  allowOrigins: string[];
  allowMethods: string[];
  allowHeaders: string[];
  exposeHeaders: string[];
  allowCredentials: boolean;
  maxAge?: number;
}

export interface HttpApiDetail extends HttpApi {
  disableExecuteApiEndpoint: boolean;
  routeSelectionExpression?: string;
  apiKeySelectionExpression?: string;
  version?: string;
  arn: string;
  cors?: HttpApiCors;
  tags: { key: string; value: string }[];
  routes: HttpApiRoute[];
  integrations: HttpApiIntegration[];
  stages: HttpApiStage[];
  authorizers: HttpApiAuthorizer[];
}

export interface ApiGatewayMethod {
  httpMethod: string;
  authorizationType?: string;
  apiKeyRequired?: boolean;
  integrationType?: string;
  integrationUri?: string;
}

export interface ApiGatewayResource {
  id: string;
  parentId?: string;
  pathPart?: string;
  path: string;
  methods: ApiGatewayMethod[];
}

export interface ApiGatewayStage {
  stageName: string;
  deploymentId?: string;
  description?: string;
  lastUpdatedDate?: string;
  variables: { key: string; value: string }[];
}

export interface SnsTopic {
  topicArn: string;
  name: string;
}

export interface EcrRepository {
  repositoryName: string;
  repositoryUri?: string;
  createdAt?: string;
  imageTagMutability?: string;
}

export interface KmsKey {
  keyId: string;
  keyArn: string;
}

export interface KmsTag {
  key: string;
  value: string;
}

export interface KmsKeyDetail {
  keyId: string;
  keyArn: string;
  description?: string;
  keyUsage?: string;
  keySpec?: string;
  origin?: string;
  keyManager?: string;
  keyState?: string;
  enabled: boolean;
  multiRegion?: boolean;
  creationDate?: string;
  deletionDate?: string;
  rotationEnabled?: boolean;
  rotationSupported: boolean;
  aliases: string[];
  tags: KmsTag[];
  rotationPeriodInDays?: number;
  nextRotationDate?: string;
  encryptionAlgorithms: string[];
  signingAlgorithms: string[];
  macAlgorithms: string[];
  pendingDeletionWindowInDays?: number;
}

export interface AccessibleEnvironment {
  accountId: string;
  accountName: string;
  roleName: string;
  ssoSessionName: string;
  ssoRegion: string;
  configuredProfileName?: string;
}

export interface ProfileCheckResult {
  profile: string;
  region: string;
  accountId?: string;
  roleName?: string;
  /** The `[sso-session ...]` this profile signs in through - what a "Log in" for it has to refresh. */
  ssoSession?: string;
  valid: boolean;
  identity?: CallerIdentity;
  error?: string;
}

export interface SsoStatus {
  loggedIn: boolean;
  expiresAt?: string;
  startUrl?: string;
  region?: string;
  loginTime?: string;
}

export interface AwsProfile {
  name: string;
  region?: string;
  sso_session?: string;
  sso_account_id?: string;
  sso_role_name?: string;
  sso_start_url?: string;
  sso_region?: string;
  output?: string;
  /** Set by `aws login` (console credentials). */
  login_session?: string;
  credential_process?: string;
  /** Only in ~/.aws/credentials (IAM access keys), no [profile] section. */
  hasStaticKeys?: boolean;
}

export interface SsoSession {
  name: string;
  sso_start_url: string;
  sso_region: string;
  sso_registration_scopes?: string;
}

// ---------------------------------------------------------------------------
// Shared tag shape for the services deepened together (ECS, RDS, Route53,
// ELB, SNS, ECR) - older services each declared their own identical
// `XxxTag`; these six share one so the Swift side can share one editor.
// ---------------------------------------------------------------------------

export interface ResourceTag {
  key: string;
  value: string;
}

// ---- ECS ----

export interface EcsServiceSummary {
  serviceName: string;
  serviceArn: string;
  status: string;
  desiredCount: number;
  runningCount: number;
  pendingCount: number;
  launchType?: string;
  taskDefinition: string;
}

export interface EcsServiceEvent {
  id: string;
  createdAt?: string;
  message: string;
}

export interface EcsDeployment {
  id: string;
  status: string;
  taskDefinition: string;
  desiredCount: number;
  runningCount: number;
  pendingCount: number;
  failedTasks: number;
  rolloutState?: string;
  rolloutStateReason?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface EcsLoadBalancerRef {
  targetGroupArn?: string;
  loadBalancerName?: string;
  containerName?: string;
  containerPort?: number;
}

export interface EcsServiceDetail extends EcsServiceSummary {
  clusterArn: string;
  platformVersion?: string;
  schedulingStrategy?: string;
  createdAt?: string;
  createdBy?: string;
  minimumHealthyPercent?: number;
  maximumPercent?: number;
  circuitBreakerEnabled?: boolean;
  circuitBreakerRollback?: boolean;
  subnets: string[];
  securityGroups: string[];
  assignPublicIp?: string;
  loadBalancers: EcsLoadBalancerRef[];
  capacityProviders: string[];
  deployments: EcsDeployment[];
  events: EcsServiceEvent[];
  tags: ResourceTag[];
}

export interface EcsContainerSummary {
  name: string;
  image?: string;
  lastStatus?: string;
  healthStatus?: string;
  exitCode?: number;
  reason?: string;
}

export interface EcsTask {
  taskArn: string;
  taskId: string;
  lastStatus?: string;
  desiredStatus?: string;
  healthStatus?: string;
  launchType?: string;
  cpu?: string;
  memory?: string;
  taskDefinition?: string;
  availabilityZone?: string;
  privateIp?: string;
  startedAt?: string;
  stoppedAt?: string;
  stoppedReason?: string;
  containers: EcsContainerSummary[];
}

export interface EcsContainerDefinition {
  name: string;
  image?: string;
  cpu?: number;
  memory?: number;
  memoryReservation?: number;
  essential?: boolean;
  portMappings: string[];
  environmentCount: number;
  secretsCount: number;
  logGroup?: string;
}

export interface EcsTaskDefinitionSummary {
  taskDefinitionArn: string;
  family: string;
  revision: number;
  cpu?: string;
  memory?: string;
  networkMode?: string;
  requiresCompatibilities: string[];
  taskRoleArn?: string;
  executionRoleArn?: string;
  registeredAt?: string;
  containers: EcsContainerDefinition[];
}

// ---- RDS ----

export interface RdsInstanceDetail {
  dbInstanceId: string;
  dbInstanceArn: string;
  dbInstanceClass: string;
  engine: string;
  engineVersion: string;
  status: string;
  endpoint?: string;
  port?: number;
  availabilityZone?: string;
  secondaryAvailabilityZone?: string;
  multiAZ: boolean;
  publiclyAccessible: boolean;
  vpcId?: string;
  subnetGroupName?: string;
  subnets: string[];
  securityGroups: string[];
  caCertificateIdentifier?: string;
  storageType: string;
  allocatedStorage: number;
  maxAllocatedStorage?: number;
  iops?: number;
  storageEncrypted: boolean;
  kmsKeyId?: string;
  masterUsername?: string;
  dbName?: string;
  parameterGroups: string[];
  optionGroups: string[];
  backupRetentionPeriod: number;
  preferredBackupWindow?: string;
  preferredMaintenanceWindow?: string;
  latestRestorableTime?: string;
  autoMinorVersionUpgrade: boolean;
  deletionProtection: boolean;
  performanceInsightsEnabled: boolean;
  iamAuthEnabled: boolean;
  dbClusterIdentifier?: string;
  createdAt?: string;
  pendingModifiedValues: string[];
  tags: ResourceTag[];
}

export interface RdsEvent {
  date?: string;
  message: string;
  categories: string[];
}

export interface RdsLogFile {
  logFileName: string;
  lastWritten?: string;
  size: number;
}

export interface RdsLogContent {
  logFileName: string;
  content: string;
  truncated: boolean;
}

export interface RdsSnapshot {
  snapshotId: string;
  snapshotType?: string;
  status?: string;
  createdAt?: string;
  allocatedStorage?: number;
  engine?: string;
  engineVersion?: string;
  percentProgress?: number;
}

export interface RdsMetricsSummary {
  cpuUtilizationAverage?: number;
  cpuUtilizationMax?: number;
  databaseConnectionsAverage?: number;
  databaseConnectionsMax?: number;
  freeStorageSpaceMin?: number;
  freeableMemoryMin?: number;
  readIopsAverage?: number;
  writeIopsAverage?: number;
}

// ---- Route53 ----

export interface Route53ZoneDetail {
  id: string;
  name: string;
  isPrivate: boolean;
  comment?: string;
  recordCount: number;
  nameServers: string[];
  vpcs: string[];
  tags: ResourceTag[];
}

export interface Route53AliasTarget {
  dnsName: string;
  hostedZoneId: string;
  evaluateTargetHealth: boolean;
}

export interface Route53Record {
  name: string;
  type: string;
  ttl?: number;
  values: string[];
  aliasTarget?: Route53AliasTarget;
  setIdentifier?: string;
  weight?: number;
  region?: string;
  failover?: string;
  healthCheckId?: string;
}

export interface Route53RecordPage {
  records: Route53Record[];
  nextRecordName?: string;
  nextRecordType?: string;
  nextRecordIdentifier?: string;
}

// ---- ELB ----

export interface LoadBalancerDetail {
  loadBalancerArn: string;
  loadBalancerName: string;
  dnsName?: string;
  canonicalHostedZoneId?: string;
  type?: string;
  scheme?: string;
  state?: string;
  stateReason?: string;
  vpcId?: string;
  ipAddressType?: string;
  createdTime?: string;
  availabilityZones: string[];
  securityGroups: string[];
  deletionProtection: boolean;
  attributes: ResourceTag[];
  tags: ResourceTag[];
}

export interface ElbRule {
  ruleArn: string;
  priority: string;
  isDefault: boolean;
  conditions: string[];
  actions: string[];
}

export interface ElbListener {
  listenerArn: string;
  protocol?: string;
  port?: number;
  sslPolicy?: string;
  certificates: string[];
  defaultActions: string[];
  rules: ElbRule[];
}

export interface ElbTargetHealth {
  targetId: string;
  port?: number;
  availabilityZone?: string;
  state?: string;
  reason?: string;
  description?: string;
}

export interface ElbTargetGroup {
  targetGroupArn: string;
  targetGroupName: string;
  protocol?: string;
  port?: number;
  targetType?: string;
  healthCheckProtocol?: string;
  healthCheckPort?: string;
  healthCheckPath?: string;
  healthCheckIntervalSeconds?: number;
  healthCheckTimeoutSeconds?: number;
  healthyThresholdCount?: number;
  unhealthyThresholdCount?: number;
  matcher?: string;
  targets: ElbTargetHealth[];
}

// ---- SNS ----

export interface SnsTopicDetail {
  topicArn: string;
  name: string;
  displayName?: string;
  owner?: string;
  subscriptionsConfirmed: number;
  subscriptionsPending: number;
  subscriptionsDeleted: number;
  kmsMasterKeyId?: string;
  fifoTopic: boolean;
  contentBasedDeduplication: boolean;
  tags: ResourceTag[];
}

export interface SnsSubscription {
  subscriptionArn: string;
  protocol: string;
  endpoint: string;
  owner?: string;
  pendingConfirmation: boolean;
}

// ---- ECR ----

export interface EcrRepositoryDetail {
  repositoryName: string;
  repositoryArn: string;
  repositoryUri: string;
  registryId: string;
  createdAt?: string;
  imageTagMutability?: string;
  scanOnPush: boolean;
  encryptionType?: string;
  kmsKey?: string;
  tags: ResourceTag[];
}

export interface EcrImage {
  imageDigest: string;
  imageTags: string[];
  pushedAt?: string;
  sizeInBytes?: number;
  lastPulledAt?: string;
  mediaType?: string;
  scanStatus?: string;
  findingCounts: ResourceTag[];
}

export interface EcrImagePage {
  images: EcrImage[];
  nextToken?: string;
}

export interface EcrScanFinding {
  name: string;
  severity: string;
  description?: string;
  uri?: string;
  packageName?: string;
  packageVersion?: string;
}

export interface EcrScanFindings {
  scanStatus?: string;
  scanStatusDescription?: string;
  completedAt?: string;
  findings: EcrScanFinding[];
}

// ---- DynamoDB table administration (Overview / Indexes / Monitor / Backups / Query / PartiQL) ----

export interface DdbIndexInfo {
  indexName: string;
  /** "GSI" | "LSI" */
  indexType: string;
  keySchema: { attributeName: string; keyType: string }[];
  projectionType?: string;
  nonKeyAttributes: string[];
  indexStatus?: string;
  itemCount?: number;
  sizeBytes?: number;
  readCapacity?: number;
  writeCapacity?: number;
}

export interface DdbTableDetail {
  tableName: string;
  tableArn: string;
  tableStatus: string;
  itemCount: number;
  tableSizeBytes: number;
  creationDateTime?: string;
  keySchema: { attributeName: string; keyType: string }[];
  attributeDefinitions: { attributeName: string; attributeType: string }[];
  /** "PAY_PER_REQUEST" (on-demand) | "PROVISIONED" */
  billingMode: string;
  readCapacity?: number;
  writeCapacity?: number;
  tableClass?: string;
  deletionProtection: boolean;
  streamEnabled: boolean;
  streamViewType?: string;
  latestStreamArn?: string;
  encryption: string;
  kmsKeyArn?: string;
  pitrEnabled: boolean;
  earliestRestorableTime?: string;
  latestRestorableTime?: string;
  ttlStatus: string;
  ttlAttribute?: string;
  replicaRegions: string[];
  indexes: DdbIndexInfo[];
  tags: ResourceTag[];
}

export interface DdbBackup {
  backupArn: string;
  backupName: string;
  backupStatus?: string;
  backupType?: string;
  createdAt?: string;
  sizeBytes?: number;
}

export interface DdbMetricsSummary {
  consumedReadCapacity?: number;
  consumedWriteCapacity?: number;
  readThrottleEvents?: number;
  writeThrottleEvents?: number;
  getItemLatencyMs?: number;
  queryLatencyMs?: number;
  scanLatencyMs?: number;
  putItemLatencyMs?: number;
}

export interface DdbQueryRequest {
  indexName?: string;
  partitionKey: { name: string; type: string; value: string };
  sortKey?: { name: string; type: string; operator: string; value: string; value2?: string };
  ascending: boolean;
  /** Matches wanted before returning (more pages are read until then). */
  limit: number;
  startKey?: Record<string, any>;
  /** Filter Builder conditions applied to each item of the partition. */
  conditions?: DdbFilterCondition[];
}

export interface DdbPageResult {
  items: Record<string, any>[];
  scannedCount?: number;
  lastEvaluatedKey?: Record<string, any>;
  nextToken?: string;
}

export * from './compute.js';
export * from './containers.js';
export * from './storage.js';
export * from './resource-page.js';
export * from './metrics.js';
