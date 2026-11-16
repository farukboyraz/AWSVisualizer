import {
  EMRClient,
  ListClustersCommand,
  DescribeClusterCommand,
  ListInstanceGroupsCommand,
  ListInstanceFleetsCommand,
  ListStepsCommand,
  ListBootstrapActionsCommand,
  AddTagsCommand,
  RemoveTagsCommand,
  type ClusterState,
} from '@aws-sdk/client-emr';
import {
  EMRServerlessClient,
  ListApplicationsCommand,
  GetApplicationCommand,
  ListJobRunsCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-emr-serverless';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, tagMap } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const emr = (p: string, r: string) => new EMRClient({ region: r, credentials: cachedCredentials(p) });
const serverless = (p: string, r: string) => new EMRServerlessClient({ region: r, credentials: cachedCredentials(p) });

const ACTIVE: ClusterState[] = ['STARTING', 'BOOTSTRAPPING', 'RUNNING', 'WAITING', 'TERMINATING'];
/** Terminated clusters stay listed (by EMR) for two months; only the last week is shown. */
const RECENT_DAYS = 7;
const STEP_LIMIT = 50;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = emr(profile, region);
  const s = serverless(profile, region);
  const [active, recent, apps] = await Promise.all([
    pageAll((Marker) => c.send(new ListClustersCommand({ Marker, ClusterStates: ACTIVE })), (r) => r.Clusters, (r) => r.Marker),
    pageAll((Marker) => c.send(new ListClustersCommand({ Marker, ClusterStates: ['TERMINATED', 'TERMINATED_WITH_ERRORS'], CreatedAfter: new Date(Date.now() - RECENT_DAYS * 86_400_000) })), (r) => r.Clusters, (r) => r.Marker).catch(() => []),
    pageAll((nextToken) => s.send(new ListApplicationsCommand({ nextToken })), (r) => r.applications, (r) => r.nextToken).catch(() => []),
  ]);
  const row = (x: (typeof active)[number], group: string) => ({ id: `cl:${x.Id}`, name: x.Name || x.Id || '', group, status: x.Status?.State, info: [x.Id, x.NormalizedInstanceHours !== undefined && `${x.NormalizedInstanceHours} normalized h`, x.Status?.StateChangeReason?.Message].filter(Boolean).join(' · ') });
  return [
    ...active.map((x) => row(x, 'Clusters')),
    ...recent.map((x) => row(x, `Terminated (last ${RECENT_DAYS} days)`)),
    ...apps.map((a) => ({ id: `app:${a.id}`, name: a.name || a.id || '', group: 'EMR Serverless applications', status: a.state, info: [a.type, a.releaseLabel, a.architecture].filter(Boolean).join(' · ') })),
  ];
}

async function clusterPage(profile: string, region: string, id: string, clusterId: string): Promise<ResourcePage> {
  const c = emr(profile, region);
  const cl = (await c.send(new DescribeClusterCommand({ ClusterId: clusterId }))).Cluster;
  if (!cl) throw httpError(`Cluster not found: ${clusterId}`, 404);
  const fleets = cl.InstanceCollectionType === 'INSTANCE_FLEET';
  const errors: string[] = [];
  const parts = await settle(
    {
      groups: fleets ? Promise.resolve([]) : pageAll((Marker) => c.send(new ListInstanceGroupsCommand({ ClusterId: clusterId, Marker })), (r) => r.InstanceGroups, (r) => r.Marker),
      fleets: fleets ? pageAll((Marker) => c.send(new ListInstanceFleetsCommand({ ClusterId: clusterId, Marker })), (r) => r.InstanceFleets, (r) => r.Marker) : Promise.resolve([]),
      steps: pageAll((Marker) => c.send(new ListStepsCommand({ ClusterId: clusterId, Marker })), (r) => r.Steps, (r) => r.Marker, STEP_LIMIT),
      bootstrap: pageAll((Marker) => c.send(new ListBootstrapActionsCommand({ ClusterId: clusterId, Marker })), (r) => r.BootstrapActions, (r) => r.Marker),
    },
    errors,
  );
  const ec2 = cl.Ec2InstanceAttributes;
  const tl = cl.Status?.Timeline;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Cluster', [
          ['Cluster ID', cl.Id],
          ['State', cl.Status?.State],
          ['State reason', cl.Status?.StateChangeReason?.Message],
          ['Release', cl.ReleaseLabel],
          ['Applications', (cl.Applications || []).map((a) => `${a.Name} ${a.Version ?? ''}`.trim())],
          ['Primary node DNS', cl.MasterPublicDnsName],
          ['Auto-terminate', cl.AutoTerminate],
          ['Termination protection', cl.TerminationProtected],
          ['Normalized instance hours', cl.NormalizedInstanceHours],
          ['Log URI', cl.LogUri],
          ['Security configuration', cl.SecurityConfiguration],
          ['Service role', cl.ServiceRole],
          ['Auto Scaling role', cl.AutoScalingRole],
          ['Created', tl?.CreationDateTime],
          ['Ready', tl?.ReadyDateTime],
          ['Ended', tl?.EndDateTime],
        ]),
        section('Network', [
          ['Subnet', ec2?.Ec2SubnetId],
          ['Availability Zone', ec2?.Ec2AvailabilityZone],
          ['Key pair', ec2?.Ec2KeyName],
          ['Instance profile', ec2?.IamInstanceProfile],
          ['Primary security group', ec2?.EmrManagedMasterSecurityGroup],
          ['Core / task security group', ec2?.EmrManagedSlaveSecurityGroup],
        ]),
      ],
    }),
    tab(fleets ? 'Instance fleets' : 'Instance groups', {
      tables: [
        fleets
          ? table(['Fleet', 'Type', 'State', 'On-Demand (target / provisioned)', 'Spot (target / provisioned)', 'Instance types'], (parts.fleets || []).map((f) => [f.Name, f.InstanceFleetType, f.Status?.State, `${f.TargetOnDemandCapacity ?? 0} / ${f.ProvisionedOnDemandCapacity ?? 0}`, `${f.TargetSpotCapacity ?? 0} / ${f.ProvisionedSpotCapacity ?? 0}`, (f.InstanceTypeSpecifications || []).map((t) => t.InstanceType)]), { statusColumn: 2, emptyMessage: 'No fleets' })
          : table(['Group', 'Type', 'State', 'Instance type', 'Market', 'Running / requested', 'Auto scaling'], (parts.groups || []).map((g) => [g.Name, g.InstanceGroupType, g.Status?.State, g.InstanceType, g.Market, `${g.RunningInstanceCount ?? 0} / ${g.RequestedInstanceCount ?? 0}`, g.AutoScalingPolicy?.Status?.State]), { statusColumn: 2, emptyMessage: 'No instance groups' }),
      ],
    }),
    tab('Steps', {
      tables: [
        table(['Step', 'State', 'Action on failure', 'Started', 'Ended', 'Jar / command'], (parts.steps || []).map((s) => [s.Name, s.Status?.State, s.ActionOnFailure, s.Status?.Timeline?.StartDateTime, s.Status?.Timeline?.EndDateTime, [s.Config?.Jar, ...(s.Config?.Args || []).slice(0, 4)].filter(Boolean).join(' ')]), {
          statusColumn: 1,
          title: `Last ${STEP_LIMIT} steps`,
          emptyMessage: 'No steps',
        }),
        table(['Bootstrap action', 'Script', 'Arguments'], (parts.bootstrap || []).map((b) => [b.Name, b.ScriptPath, b.Args]), { title: 'Bootstrap actions', emptyMessage: 'No bootstrap actions' }),
      ],
    }),
  ];
  if (cl.Configurations?.length) tabs.push(tab('Configurations', { json: JSON.stringify(cl.Configurations, null, 2) }));
  return { id, title: cl.Name || clusterId, subtitle: `EMR ${cl.ReleaseLabel ?? ''} cluster`, status: cl.Status?.State, arn: cl.ClusterArn, tabs, tags: tagList(cl.Tags), actions: [], errors };
}

async function appPage(profile: string, region: string, id: string, appId: string): Promise<ResourcePage> {
  const s = serverless(profile, region);
  const a = (await s.send(new GetApplicationCommand({ applicationId: appId }))).application;
  if (!a) throw httpError(`Application not found: ${appId}`, 404);
  const errors: string[] = [];
  const { runs } = await settle({ runs: s.send(new ListJobRunsCommand({ applicationId: appId, maxResults: 50 })) }, errors);
  return {
    id,
    title: a.name || appId,
    subtitle: `EMR Serverless ${a.type ?? ''} application`,
    status: a.state,
    arn: a.arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Application', [
            ['Application ID', a.applicationId],
            ['Type', a.type],
            ['Release', a.releaseLabel],
            ['Architecture', a.architecture],
            ['State', a.state],
            ['State details', a.stateDetails],
            ['Maximum capacity', a.maximumCapacity ? `${a.maximumCapacity.cpu ?? '-'} · ${a.maximumCapacity.memory ?? '-'} · ${a.maximumCapacity.disk ?? '-'}` : undefined],
            ['Auto start', a.autoStartConfiguration?.enabled],
            ['Auto stop', a.autoStopConfiguration?.enabled ? `after ${a.autoStopConfiguration.idleTimeoutMinutes ?? 15} min idle` : false],
            ['Subnets', a.networkConfiguration?.subnetIds],
            ['Custom image', a.imageConfiguration?.imageUri],
            ['Created', a.createdAt],
            ['Updated', a.updatedAt],
          ]),
        ],
        tables: [table(['Worker', 'Count', 'CPU', 'Memory', 'Disk'], Object.entries(a.initialCapacity || {}).map(([k, v]) => [k, v.workerCount, v.workerConfiguration?.cpu, v.workerConfiguration?.memory, v.workerConfiguration?.disk]), { title: 'Pre-initialized capacity', emptyMessage: 'None' })],
      }),
      tab('Job runs', {
        tables: [table(['Job', 'State', 'Created', 'Updated', 'Created by', 'Details'], (runs?.jobRuns || []).map((j) => [j.name || j.id, j.state, j.createdAt, j.updatedAt, j.createdBy, j.stateDetails]), { statusColumn: 1, title: 'Last 50 job runs', emptyMessage: 'No job runs' })],
      }),
    ],
    tags: tagMap(a.tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'cl') return clusterPage(profile, region, id, rest);
  if (kind === 'app') return appPage(profile, region, id, rest);
  throw httpError(`Unknown EMR page: ${id}`, 400);
}

export const emrAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    const [kind, rest] = splitId(id);
    if (kind === 'cl') await emr(profile, region).send(new AddTagsCommand({ ResourceId: rest, Tags: [{ Key: key, Value: value }] }));
    else if (kind === 'app' && arn) await serverless(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
    else throw httpError(`Unknown EMR resource: ${id}`, 400);
  },
  async removeTag(profile, region, id, arn, key) {
    const [kind, rest] = splitId(id);
    if (kind === 'cl') await emr(profile, region).send(new RemoveTagsCommand({ ResourceId: rest, TagKeys: [key] }));
    else if (kind === 'app' && arn) await serverless(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
    else throw httpError(`Unknown EMR resource: ${id}`, 400);
  },
  countable: (row) => row.group === 'Clusters' || row.id.startsWith('app:'),
};
