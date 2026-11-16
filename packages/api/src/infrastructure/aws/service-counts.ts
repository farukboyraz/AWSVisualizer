import { getEnvironments } from './eb.js';
import { listFunctions } from './lambda.js';
import { listInstances } from './ec2.js';
import { listClusters } from './ecs.js';
import { listRdsInstances } from './rds.js';
import { listTables } from './dynamodb.js';
import { listBuckets } from './s3.js';
import { listQueues } from './sqs.js';
import { listAlarms } from './cloudwatch.js';
import { listDistributions } from './cloudfront.js';
import { listHostedZones } from './route53.js';
import { listRepositories as listCodeCommitRepositories } from './codecommit.js';
import { listSecrets } from './secrets-manager.js';
import { listStacks } from './cloudformation.js';
import { listLoadBalancers } from './elb.js';
import { listRestApis } from './api-gateway.js';
import { listTopics } from './sns.js';
import { listRepositories as listEcrRepositories } from './ecr.js';
import { listKeys } from './kms.js';
import { listAutoScalingGroups } from './autoscaling.js';
import { listBatchJobQueues } from './batch.js';
import { listLightsailInstances } from './lightsail.js';
import { listSarApplications } from './serverless-repo.js';
import { listOutposts } from './outposts.js';
import { listOptedInZones, listEnclaveInstances } from './ec2-edge.js';
import { listEksClusters } from './eks.js';
import { listFargateItems } from './fargate.js';
import { listAppRunnerServices } from './apprunner.js';
import { listEfsFileSystems } from './efs.js';
import { listFsxFileSystems } from './fsx.js';
import { listEbsVolumes } from './ebs.js';
import { listGlacierVaults } from './glacier.js';
import { listStorageGateways } from './storage-gateway.js';
import { listBackupItems } from './backup.js';
import { PAGE_SERVICES, pageCountLister } from './page-services.js';

type Lister = (profile: string, region: string) => Promise<unknown[]>;

export const SERVICE_LISTERS: Record<string, Lister> = {
  elasticbeanstalk: getEnvironments,
  lambda: listFunctions,
  ec2: listInstances,
  ecs: listClusters,
  rds: listRdsInstances,
  dynamodb: listTables,
  s3: listBuckets,
  sqs: listQueues,
  cloudwatch: listAlarms,
  cloudfront: listDistributions,
  route53: listHostedZones,
  codecommit: listCodeCommitRepositories,
  secretsmanager: listSecrets,
  cloudformation: listStacks,
  elasticloadbalancing: listLoadBalancers,
  apigateway: listRestApis,
  sns: listTopics,
  ecr: listEcrRepositories,
  kms: listKeys,
  'ec2-autoscaling': listAutoScalingGroups,
  batch: listBatchJobQueues,
  lightsail: listLightsailInstances,
  serverlessapplicationrepository: listSarApplications,
  outposts: listOutposts,
  wavelength: (p, r) => listOptedInZones(p, r, 'wavelength-zone'),
  localzones: (p, r) => listOptedInZones(p, r, 'local-zone'),
  nitroenclaves: listEnclaveInstances,
  eks: listEksClusters,
  fargate: listFargateItems,
  apprunner: listAppRunnerServices,
  efs: listEfsFileSystems,
  fsx: listFsxFileSystems,
  ebs: listEbsVolumes,
  s3glacier: listGlacierVaults,
  storagegateway: listStorageGateways,
  backup: listBackupItems,
  ...Object.fromEntries(Object.keys(PAGE_SERVICES).filter((id) => !PAGE_SERVICES[id].uncounted).map((id) => [id, pageCountLister(id)])),
};

export async function getServiceCounts(
  profile: string,
  region: string,
  serviceIds: string[]
): Promise<Record<string, number | null>> {
  const entries = await Promise.all(
    serviceIds.map(async (id) => {
      const lister = SERVICE_LISTERS[id];
      if (!lister) return [id, null] as const;
      try {
        const items = await lister(profile, region);
        return [id, items.length] as const;
      } catch {
        return [id, null] as const;
      }
    })
  );

  return Object.fromEntries(entries);
}
