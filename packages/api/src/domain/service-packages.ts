/**
 * Which npm packages each catalog service needs. The sidecar itself only
 * needs CORE_PACKAGES (they live in packages/api's `dependencies`); every
 * service SDK is installed on demand into the user's modules folder
 * (see infrastructure/packages/modules-dir.ts) and is only a devDependency
 * of the repo, for type checking.
 */

/** Every AWS SDK package is pinned to this exact version. */
export const SDK_VERSION = '3.654.0';

/** What the sidecar needs to start at all (login, profiles, settings). */
export const CORE_PACKAGES = ['express', 'diff', 'jszip', 'tsx', '@aws-sdk/client-sts', '@aws-sdk/client-sso', '@aws-sdk/credential-providers'];

const c = (...names: string[]) => names.map((n) => (n.startsWith('util-') ? `@aws-sdk/${n}` : `@aws-sdk/client-${n}`));

export const SERVICE_PACKAGES: Record<string, string[]> = {
  // Compute
  ec2: c('ec2'),
  lambda: c('lambda', 'cloudwatch'),
  elasticbeanstalk: c('elastic-beanstalk'),
  lightsail: c('lightsail'),
  batch: c('batch'),
  'ec2-autoscaling': c('auto-scaling'),
  outposts: c('outposts'),
  serverlessapplicationrepository: c('serverlessapplicationrepository'),
  wavelength: c('ec2'),
  localzones: c('ec2'),
  nitroenclaves: c('ec2'),
  // Containers
  ecs: c('ecs'),
  eks: c('eks'),
  ecr: c('ecr'),
  fargate: c('ecs', 'eks'),
  apprunner: c('apprunner'),
  // Storage
  s3: c('s3'),
  efs: c('efs'),
  fsx: c('fsx'),
  ebs: c('ec2'),
  s3glacier: c('glacier'),
  storagegateway: c('storage-gateway'),
  backup: c('backup'),
  // Database
  rds: c('rds', 'cloudwatch'),
  dynamodb: c('dynamodb', 'util-dynamodb', 'cloudwatch'),
  elasticache: c('elasticache'),
  redshift: c('redshift', 'redshift-serverless', 'cloudwatch'),
  neptune: c('rds', 'cloudwatch'),
  documentdb: c('rds', 'cloudwatch'),
  keyspaces: c('keyspaces'),
  timestream: c('timestream-write'),
  qldb: [], // shut down by AWS - information page
  memorydb: c('memorydb'),
  'rds-proxy': c('rds'),
  dms: c('database-migration-service'),
  // Networking & Content Delivery
  vpc: c('ec2'),
  cloudfront: c('cloudfront'),
  route53: c('route-53'),
  apigateway: c('api-gateway', 'apigatewayv2'),
  elasticloadbalancing: c('elastic-load-balancing-v2'),
  directconnect: c('direct-connect'),
  globalaccelerator: c('global-accelerator'),
  privatelink: c('ec2'),
  transitgateway: c('ec2'),
  cloudmap: c('servicediscovery'),
  appmesh: [], // shut down by AWS - information page
  vpnclient: c('ec2'),
  // Security, Identity & Compliance
  iam: c('iam'),
  cognito: c('cognito-identity', 'cognito-identity-provider'),
  guardduty: c('guardduty'),
  inspector: c('inspector2'),
  securityhub: c('securityhub'),
  kms: c('kms'),
  secretsmanager: c('secrets-manager'),
  waf: c('wafv2', 'shield'),
  acm: c('acm'),
  macie: c('macie2'),
  directoryservice: c('directory-service'),
  artifact: c('artifact'),
  firewallmanager: c('fms'),
  detective: c('detective'),
  'iam-identitycenter': c('sso-admin', 'identitystore'),
  networkfirewall: c('network-firewall'),
  verifiedaccess: c('ec2'),
  resourceaccessmanager: c('ram'),
  // Management & Governance
  cloudformation: c('cloudformation'),
  cloudwatch: c('cloudwatch', 'cloudwatch-logs'),
  cloudtrail: c('cloudtrail'),
  config: c('config-service'),
  systemsmanager: c('ssm'),
  organizations: c('organizations'),
  controltower: c('controltower'),
  trustedadvisor: c('trustedadvisor'),
  servicecatalog: c('service-catalog'),
  licensemanager: c('license-manager'),
  computeoptimizer: c('compute-optimizer'),
  costexplorer: c('cost-explorer'),
  budgets: c('budgets'),
  healthdashboard: c('health'),
  wellarchitectedtool: c('wellarchitected'),
  resourcegroups: c('resource-groups', 'resource-groups-tagging-api'),
  opsworks: [], // shut down by AWS - information page
  launchwizard: c('launch-wizard'),
  // Developer Tools
  codecommit: c('codecommit'),
  codebuild: c('codebuild'),
  codepipeline: c('codepipeline'),
  codedeploy: c('codedeploy'),
  codeartifact: c('codeartifact'),
  cloud9: c('cloud9'),
  xray: c('xray'),
  codestar: c('codestar-connections', 'codestar-notifications'),
  // Information pages only (no public API for AWS profiles): nothing to install.
  cloudshell: [],
  codewhisperer: [],
  codecatalyst: [],
  // Analytics
  athena: c('athena'),
  emr: c('emr', 'emr-serverless'),
  kinesis: c('kinesis', 'firehose', 'kinesis-analytics-v2'),
  opensearch: c('opensearch', 'opensearchserverless'),
  quicksight: c('quicksight'),
  glue: c('glue'),
  datazone: c('datazone'),
  lakeformation: c('lakeformation'),
  msk: c('kafka'),
  datapipeline: c('data-pipeline'),
  cloudsearch: c('cloudsearch'),
  // Machine Learning
  sagemaker: c('sagemaker'),
  bedrock: c('bedrock', 'bedrock-agent'),
  rekognition: c('rekognition'),
  comprehend: c('comprehend'),
  textract: c('textract'),
  polly: c('polly'),
  transcribe: c('transcribe'),
  translate: c('translate'),
  lex: c('lex-models-v2'),
  personalize: c('personalize'),
  forecast: c('forecast'),
  kendra: c('kendra'),
  q: c('qbusiness'),
  // Application Integration
  sqs: c('sqs'),
  sns: c('sns'),
  eventbridge: c('eventbridge', 'scheduler'),
  stepfunctions: c('sfn'),
  appflow: c('appflow'),
  mq: c('mq'),
  apppipes: c('pipes'),
  // Migration & Transfer
  migrationhub: c('migration-hub'),
  datasync: c('datasync'),
  transferfamily: c('transfer'),
  applicationdiscoveryservice: c('application-discovery-service'),
  snowfamily: [], // shut down by AWS - information page
  mgn: c('mgn'),
  // Media Services (Elastic Transcoder was discontinued in Nov 2025: info page, no package)
  elastictranscoder: [],
  mediaconvert: c('mediaconvert'),
  medialive: c('medialive'),
  mediapackage: c('mediapackage', 'mediapackagev2'),
  mediastore: [], // shut down by AWS - information page
  ivs: c('ivs'),
  // Internet of Things (IoT Analytics ended in Dec 2025: info page, no package)
  iotcore: c('iot'),
  iotanalytics: [],
  iotgreengrass: c('greengrassv2'),
  iotdevicedefender: c('iot'),
  iotsitewise: c('iotsitewise'),
  // Business Applications
  workmail: c('workmail'),
  chime: c('chime-sdk-voice'),
  connect: c('connect'),
  pinpoint: [], // shut down by AWS - information page
  ses: c('sesv2'),
  honeycode: [], // shut down by AWS - information page
  // End User Computing
  workspaces: c('workspaces'),
  appstream: c('appstream'),
  worklink: [], // shut down by AWS - information page
  // Front-End Web & Mobile
  amplify: c('amplify'),
  appsync: c('appsync'),
  devicefarm: c('device-farm'),
  location: c('location'),
  // Blockchain
  managedblockchain: c('managedblockchain'),
  'qldb-blockchain': [], // QLDB was shut down - information page
  // Satellite, Quantum, Robotics, Game Tech
  groundstation: c('groundstation'),
  braket: c('braket'),
  robomaker: [], // shut down by AWS - information page
  gamelift: c('gamelift'),
};

/** Every installable (non-core) package, de-duplicated. */
export const OPTIONAL_PACKAGES = new Set(Object.values(SERVICE_PACKAGES).flat());

/** `@aws-sdk/client-s3/dist-cjs/x` → `@aws-sdk/client-s3`. */
export function packageName(request: string): string {
  const parts = request.split('/');
  return request.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
}

/** Services whose packages include `pkg` (a package can serve several, e.g. client-ec2). */
export function servicesUsing(pkg: string): string[] {
  return Object.entries(SERVICE_PACKAGES)
    .filter(([, pkgs]) => pkgs.includes(pkg))
    .map(([id]) => id);
}
