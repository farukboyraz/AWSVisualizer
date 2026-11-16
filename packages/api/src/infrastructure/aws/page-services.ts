import type { PageServiceAdapter } from './page-adapter.js';
import { elastiCacheAdapter } from './elasticache.js';
import { memoryDbAdapter } from './memorydb.js';
import { redshiftAdapter } from './redshift.js';
import { neptuneAdapter, documentDbAdapter } from './rds-clusters.js';
import { keyspacesAdapter } from './keyspaces.js';
import { timestreamAdapter } from './timestream.js';
import { qldbAdapter } from './qldb.js';
import { rdsProxyAdapter } from './rds-proxy.js';
import { dmsAdapter } from './dms.js';
import { vpcAdapter } from './vpc.js';
import { privateLinkAdapter } from './privatelink.js';
import { transitGatewayAdapter } from './transit-gateway.js';
import { clientVpnAdapter } from './client-vpn.js';
import { directConnectAdapter } from './direct-connect.js';
import { globalAcceleratorAdapter } from './global-accelerator.js';
import { cloudMapAdapter } from './cloud-map.js';
import { appMeshAdapter } from './app-mesh.js';
import { iamAdapter } from './iam.js';
import { cognitoAdapter } from './cognito.js';
import { guardDutyAdapter } from './guardduty.js';
import { inspectorAdapter } from './inspector.js';
import { securityHubAdapter } from './securityhub.js';
import { wafAdapter } from './waf.js';
import { acmAdapter } from './acm.js';
import { macieAdapter } from './macie.js';
import { directoryServiceAdapter } from './directory-service.js';
import { artifactAdapter } from './artifact.js';
import { firewallManagerAdapter } from './firewall-manager.js';
import { detectiveAdapter } from './detective.js';
import { identityCenterAdapter } from './identity-center.js';
import { networkFirewallAdapter } from './network-firewall.js';
import { verifiedAccessAdapter } from './verified-access.js';
import { ramAdapter } from './ram.js';
import { cloudTrailAdapter } from './cloudtrail.js';
import { configAdapter } from './config-service.js';
import { ssmAdapter } from './ssm.js';
import { organizationsAdapter } from './organizations.js';
import { controlTowerAdapter } from './control-tower.js';
import { trustedAdvisorAdapter } from './trusted-advisor.js';
import { serviceCatalogAdapter } from './service-catalog.js';
import { licenseManagerAdapter } from './license-manager.js';
import { computeOptimizerAdapter } from './compute-optimizer.js';
import { costExplorerAdapter } from './cost-explorer-pages.js';
import { budgetsAdapter } from './budgets.js';
import { healthAdapter } from './health.js';
import { wellArchitectedAdapter } from './well-architected.js';
import { resourceGroupsAdapter } from './resource-groups.js';
import { opsWorksAdapter } from './opsworks.js';
import { launchWizardAdapter } from './launch-wizard.js';
import { codeBuildAdapter } from './codebuild.js';
import { codePipelineAdapter } from './codepipeline.js';
import { codeDeployAdapter } from './codedeploy.js';
import { codeArtifactAdapter } from './codeartifact.js';
import { cloud9Adapter } from './cloud9.js';
import { xrayAdapter } from './xray.js';
import { codeStarAdapter } from './codestar.js';
import { cloudShellAdapter } from './cloudshell.js';
import { qDeveloperAdapter } from './q-developer.js';
import { codeCatalystAdapter } from './codecatalyst.js';
import { athenaAdapter } from './athena.js';
import { emrAdapter } from './emr.js';
import { kinesisAdapter } from './kinesis.js';
import { openSearchAdapter } from './opensearch.js';
import { quickSightAdapter } from './quicksight.js';
import { glueAdapter } from './glue.js';
import { dataZoneAdapter } from './datazone.js';
import { lakeFormationAdapter } from './lake-formation.js';
import { mskAdapter } from './msk.js';
import { dataPipelineAdapter } from './data-pipeline.js';
import { cloudSearchAdapter } from './cloudsearch.js';
import { sageMakerAdapter } from './sagemaker.js';
import { bedrockAdapter } from './bedrock.js';
import { rekognitionAdapter } from './rekognition.js';
import { comprehendAdapter } from './comprehend.js';
import { textractAdapter } from './textract.js';
import { pollyAdapter } from './polly.js';
import { transcribeAdapter } from './transcribe.js';
import { translateAdapter } from './translate.js';
import { lexAdapter } from './lex.js';
import { personalizeAdapter } from './personalize.js';
import { forecastAdapter } from './forecast.js';
import { kendraAdapter } from './kendra.js';
import { qBusinessAdapter } from './qbusiness.js';
import { eventBridgeAdapter } from './eventbridge.js';
import { stepFunctionsAdapter } from './step-functions.js';
import { appFlowAdapter } from './appflow.js';
import { mqAdapter } from './mq.js';
import { pipesAdapter } from './eventbridge-pipes.js';
import { migrationHubAdapter } from './migration-hub.js';
import { dataSyncAdapter } from './datasync.js';
import { transferAdapter } from './transfer-family.js';
import { discoveryAdapter } from './application-discovery.js';
import { snowAdapter } from './snow-family.js';
import { mgnAdapter } from './mgn.js';
import { elasticTranscoderAdapter } from './elastic-transcoder.js';
import { mediaConvertAdapter } from './mediaconvert.js';
import { mediaLiveAdapter } from './medialive.js';
import { mediaPackageAdapter } from './mediapackage.js';
import { mediaStoreAdapter } from './mediastore.js';
import { ivsAdapter } from './ivs.js';
import { iotCoreAdapter } from './iot-core.js';
import { iotAnalyticsAdapter } from './iot-analytics.js';
import { greengrassAdapter } from './greengrass.js';
import { deviceDefenderAdapter } from './device-defender.js';
import { siteWiseAdapter } from './iot-sitewise.js';
import { workMailAdapter } from './workmail.js';
import { chimeAdapter } from './chime.js';
import { connectAdapter } from './connect.js';
import { pinpointAdapter } from './pinpoint.js';
import { sesAdapter } from './ses.js';
import { honeycodeAdapter } from './honeycode.js';
import { workSpacesAdapter } from './workspaces.js';
import { appStreamAdapter } from './appstream.js';
import { workLinkAdapter } from './worklink.js';
import { amplifyAdapter } from './amplify.js';
import { appSyncAdapter } from './appsync.js';
import { deviceFarmAdapter } from './device-farm.js';
import { locationAdapter } from './location.js';
import { managedBlockchainAdapter } from './managed-blockchain.js';
import { groundStationAdapter } from './ground-station.js';
import { braketAdapter } from './braket.js';
import { roboMakerAdapter } from './robomaker.js';
import { gameLiftAdapter } from './gamelift.js';

/** Catalog id → adapter for every service on the shared ResourcePage model. */
export const PAGE_SERVICES: Record<string, PageServiceAdapter> = {
  // Database
  elasticache: elastiCacheAdapter,
  memorydb: memoryDbAdapter,
  redshift: redshiftAdapter,
  neptune: neptuneAdapter,
  documentdb: documentDbAdapter,
  keyspaces: keyspacesAdapter,
  timestream: timestreamAdapter,
  qldb: qldbAdapter,
  'rds-proxy': rdsProxyAdapter,
  dms: dmsAdapter,
  // Networking & Content Delivery
  vpc: vpcAdapter,
  privatelink: privateLinkAdapter,
  transitgateway: transitGatewayAdapter,
  vpnclient: clientVpnAdapter,
  directconnect: directConnectAdapter,
  globalaccelerator: globalAcceleratorAdapter,
  cloudmap: cloudMapAdapter,
  appmesh: appMeshAdapter,
  // Security, Identity & Compliance
  iam: iamAdapter,
  cognito: cognitoAdapter,
  guardduty: guardDutyAdapter,
  inspector: inspectorAdapter,
  securityhub: securityHubAdapter,
  waf: wafAdapter,
  acm: acmAdapter,
  macie: macieAdapter,
  directoryservice: directoryServiceAdapter,
  artifact: artifactAdapter,
  firewallmanager: firewallManagerAdapter,
  detective: detectiveAdapter,
  'iam-identitycenter': identityCenterAdapter,
  networkfirewall: networkFirewallAdapter,
  verifiedaccess: verifiedAccessAdapter,
  resourceaccessmanager: ramAdapter,
  // Management & Governance
  cloudtrail: cloudTrailAdapter,
  config: configAdapter,
  systemsmanager: ssmAdapter,
  organizations: organizationsAdapter,
  controltower: controlTowerAdapter,
  trustedadvisor: trustedAdvisorAdapter,
  servicecatalog: serviceCatalogAdapter,
  licensemanager: licenseManagerAdapter,
  computeoptimizer: computeOptimizerAdapter,
  costexplorer: costExplorerAdapter,
  budgets: budgetsAdapter,
  healthdashboard: healthAdapter,
  wellarchitectedtool: wellArchitectedAdapter,
  resourcegroups: resourceGroupsAdapter,
  opsworks: opsWorksAdapter,
  launchwizard: launchWizardAdapter,
  // Developer Tools
  codebuild: codeBuildAdapter,
  codepipeline: codePipelineAdapter,
  codedeploy: codeDeployAdapter,
  codeartifact: codeArtifactAdapter,
  cloudshell: cloudShellAdapter,
  cloud9: cloud9Adapter,
  xray: xrayAdapter,
  codestar: codeStarAdapter,
  codewhisperer: qDeveloperAdapter,
  codecatalyst: codeCatalystAdapter,
  // Analytics
  athena: athenaAdapter,
  emr: emrAdapter,
  kinesis: kinesisAdapter,
  opensearch: openSearchAdapter,
  quicksight: quickSightAdapter,
  glue: glueAdapter,
  datazone: dataZoneAdapter,
  lakeformation: lakeFormationAdapter,
  msk: mskAdapter,
  datapipeline: dataPipelineAdapter,
  cloudsearch: cloudSearchAdapter,
  // Machine Learning
  sagemaker: sageMakerAdapter,
  bedrock: bedrockAdapter,
  rekognition: rekognitionAdapter,
  comprehend: comprehendAdapter,
  textract: textractAdapter,
  polly: pollyAdapter,
  transcribe: transcribeAdapter,
  translate: translateAdapter,
  lex: lexAdapter,
  personalize: personalizeAdapter,
  forecast: forecastAdapter,
  kendra: kendraAdapter,
  q: qBusinessAdapter,
  // Application Integration
  eventbridge: eventBridgeAdapter,
  stepfunctions: stepFunctionsAdapter,
  appflow: appFlowAdapter,
  mq: mqAdapter,
  apppipes: pipesAdapter,
  // Migration & Transfer
  migrationhub: migrationHubAdapter,
  datasync: dataSyncAdapter,
  transferfamily: transferAdapter,
  applicationdiscoveryservice: discoveryAdapter,
  snowfamily: snowAdapter,
  mgn: mgnAdapter,
  // Media Services
  elastictranscoder: elasticTranscoderAdapter,
  mediaconvert: mediaConvertAdapter,
  medialive: mediaLiveAdapter,
  mediapackage: mediaPackageAdapter,
  mediastore: mediaStoreAdapter,
  ivs: ivsAdapter,
  // Internet of Things
  iotcore: iotCoreAdapter,
  iotanalytics: iotAnalyticsAdapter,
  iotgreengrass: greengrassAdapter,
  iotdevicedefender: deviceDefenderAdapter,
  iotsitewise: siteWiseAdapter,
  // Business Applications
  workmail: workMailAdapter,
  chime: chimeAdapter,
  connect: connectAdapter,
  pinpoint: pinpointAdapter,
  ses: sesAdapter,
  honeycode: honeycodeAdapter,
  // End User Computing
  workspaces: workSpacesAdapter,
  appstream: appStreamAdapter,
  worklink: workLinkAdapter,
  // Front-End Web & Mobile
  amplify: amplifyAdapter,
  appsync: appSyncAdapter,
  devicefarm: deviceFarmAdapter,
  location: locationAdapter,
  // Blockchain (QLDB is listed under Database too - same page)
  managedblockchain: managedBlockchainAdapter,
  'qldb-blockchain': qldbAdapter,
  // Satellite, Quantum Technologies, Robotics, Game Tech
  groundstation: groundStationAdapter,
  braket: braketAdapter,
  robomaker: roboMakerAdapter,
  gamelift: gameLiftAdapter,
};

/** Dashboard count: top-level resources only (keyspaces / databases / namespaces, not what's inside them). */
export function pageCountLister(id: string) {
  const adapter = PAGE_SERVICES[id];
  return async (profile: string, region: string) =>
    (await adapter.list(profile, region)).filter(
      (row) => (adapter.countable ? adapter.countable(row) : true) && !row.id.startsWith('tb:') && !(id === 'cloudmap' && row.id.startsWith('svc:')) && !(id === 'vpc' && row.id.startsWith('sg:')),
    );
}
