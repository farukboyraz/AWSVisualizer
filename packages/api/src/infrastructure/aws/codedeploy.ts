import {
  CodeDeployClient,
  ListApplicationsCommand,
  BatchGetApplicationsCommand,
  ListDeploymentGroupsCommand,
  BatchGetDeploymentGroupsCommand,
  ListDeploymentsCommand,
  BatchGetDeploymentsCommand,
  ListDeploymentConfigsCommand,
  GetDeploymentConfigCommand,
  ListApplicationRevisionsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type RevisionLocation,
} from '@aws-sdk/client-codedeploy';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, tagList, accountId } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new CodeDeployClient({ region: r, credentials: cachedCredentials(p) });

const DEPLOYMENT_LIMIT = 25;

const revisionText = (r?: RevisionLocation) => {
  if (!r) return undefined;
  if (r.s3Location) return `s3://${r.s3Location.bucket}/${r.s3Location.key}${r.s3Location.version ? ` (${r.s3Location.version})` : ''}`;
  if (r.gitHubLocation) return `${r.gitHubLocation.repository}@${r.gitHubLocation.commitId?.slice(0, 12)}`;
  if (r.appSpecContent || r.string) return 'AppSpec content';
  return r.revisionType;
};

async function deployments(c: CodeDeployClient, applicationName: string, deploymentGroupName?: string) {
  const r = await c.send(new ListDeploymentsCommand({ applicationName, deploymentGroupName }));
  const ids = (r.deployments || []).slice(0, DEPLOYMENT_LIMIT);
  if (!ids.length) return [];
  const infos = (await c.send(new BatchGetDeploymentsCommand({ deploymentIds: ids }))).deploymentsInfo || [];
  return infos.sort((a, b) => (b.createTime?.getTime() ?? 0) - (a.createTime?.getTime() ?? 0));
}

const deploymentTable = (rows: Awaited<ReturnType<typeof deployments>>, withGroup: boolean) =>
  table(
    [...(withGroup ? ['Group'] : []), 'Deployment', 'Status', 'Created', 'Completed', 'Config', 'Revision', 'Instances (ok / failed)', 'Error'],
    rows.map((d) => [
      ...(withGroup ? [d.deploymentGroupName] : []),
      d.deploymentId,
      d.status,
      d.createTime,
      d.completeTime,
      d.deploymentConfigName,
      revisionText(d.revision),
      d.deploymentOverview ? `${d.deploymentOverview.Succeeded ?? 0} / ${d.deploymentOverview.Failed ?? 0}` : undefined,
      d.errorInformation?.message,
    ]),
    { statusColumn: withGroup ? 2 : 1, title: `Last ${DEPLOYMENT_LIMIT} deployments`, emptyMessage: 'No deployments' },
  );

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const names = await pageAll((nextToken) => c.send(new ListApplicationsCommand({ nextToken })), (r) => r.applications, (r) => r.nextToken);
  const chunks = Array.from({ length: Math.ceil(names.length / 100) }, (_, i) => names.slice(i * 100, i * 100 + 100));
  const apps = (await mapLimited(chunks, 3, (applicationNames) => c.send(new BatchGetApplicationsCommand({ applicationNames })).then((r) => r.applicationsInfo || []))).flat();
  const groups = await mapLimited(apps, 5, (a) => pageAll((nextToken) => c.send(new ListDeploymentGroupsCommand({ applicationName: a.applicationName, nextToken })), (r) => r.deploymentGroups, (r) => r.nextToken).catch(() => [] as string[]));
  const custom = await pageAll((nextToken) => c.send(new ListDeploymentConfigsCommand({ nextToken })), (r) => r.deploymentConfigsList, (r) => r.nextToken).catch(() => [] as string[]);
  return [
    ...apps
      .map((a, i) => ({ app: a, groups: groups[i] }))
      .sort((x, y) => (x.app.applicationName || '').localeCompare(y.app.applicationName || ''))
      .flatMap(({ app, groups: gs }) => [
        { id: `app:${app.applicationName}`, name: app.applicationName || '', group: 'Applications', info: `${app.computePlatform ?? ''} · ${gs.length} deployment groups` },
        ...gs.map((g) => ({ id: `dg:${app.applicationName}|${g}`, name: `${app.applicationName} / ${g}`, group: 'Deployment groups', info: app.computePlatform })),
      ]),
    // AWS's predefined CodeDeployDefault.* configs are left out.
    ...custom.filter((n) => !n.startsWith('CodeDeployDefault.')).map((n) => ({ id: `cfg:${n}`, name: n, group: 'Custom deployment configurations' })),
  ];
}

async function appPage(c: CodeDeployClient, profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const a = (await c.send(new BatchGetApplicationsCommand({ applicationNames: [name] }))).applicationsInfo?.[0];
  if (!a) throw httpError(`Application not found: ${name}`, 404);
  const arn = `arn:aws:codedeploy:${region}:${await accountId(profile, region)}:application:${name}`;
  const errors: string[] = [];
  const parts = await settle(
    {
      groups: pageAll((nextToken) => c.send(new ListDeploymentGroupsCommand({ applicationName: name, nextToken })), (r) => r.deploymentGroups, (r) => r.nextToken),
      deployments: deployments(c, name),
      revisions: c.send(new ListApplicationRevisionsCommand({ applicationName: name, sortBy: 'lastUsedTime', sortOrder: 'descending' })),
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
    },
    errors,
  );
  return {
    id,
    title: name,
    subtitle: `${a.computePlatform ?? ''} application`,
    arn,
    tabs: [
      tab('Details', {
        sections: [section('Application', [['Name', name], ['Compute platform', a.computePlatform], ['Application ID', a.applicationId], ['GitHub', a.linkedToGitHub ? a.gitHubAccountName : undefined], ['Created', a.createTime]])],
        tables: [table(['Deployment group'], (parts.groups || []).map((g) => [g]), { title: 'Deployment groups', emptyMessage: 'No deployment groups' })],
      }),
      tab('Deployments', { tables: [deploymentTable(parts.deployments || [], true)] }),
      tab('Revisions', {
        tables: [table(['Revision'], (parts.revisions?.revisions || []).slice(0, 50).map((r) => [revisionText(r)]), { title: 'Registered revisions (most recently used first)', emptyMessage: 'No revisions' })],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function groupPage(c: CodeDeployClient, profile: string, region: string, id: string, rest: string): Promise<ResourcePage> {
  const [app, name] = rest.split('|');
  if (!app || !name) throw httpError(`Bad deployment group id: ${rest}`, 400);
  const g = (await c.send(new BatchGetDeploymentGroupsCommand({ applicationName: app, deploymentGroupNames: [name] }))).deploymentGroupsInfo?.[0];
  if (!g) throw httpError(`Deployment group not found: ${rest}`, 404);
  const arn = `arn:aws:codedeploy:${region}:${await accountId(profile, region)}:deploymentgroup:${app}/${name}`;
  const errors: string[] = [];
  const parts = await settle({ deployments: deployments(c, app, name), tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })) }, errors);
  const lb = g.loadBalancerInfo;
  const bg = g.blueGreenDeploymentConfiguration;
  return {
    id,
    title: name,
    subtitle: `Deployment group of ${app}`,
    status: g.lastAttemptedDeployment?.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Deployment group', [
            ['Application', app],
            ['Compute platform', g.computePlatform],
            ['Deployment config', g.deploymentConfigName],
            ['Deployment type', g.deploymentStyle?.deploymentType],
            ['Traffic control', g.deploymentStyle?.deploymentOption],
            ['Service role', g.serviceRoleArn],
            ['Auto Scaling groups', (g.autoScalingGroups || []).map((x) => x.name)],
            ['ECS services', (g.ecsServices || []).map((x) => `${x.clusterName}/${x.serviceName}`)],
            ['Load balancer', [...(lb?.targetGroupInfoList || []).map((x) => x.name), ...(lb?.elbInfoList || []).map((x) => x.name), ...(lb?.targetGroupPairInfoList || []).flatMap((x) => (x.targetGroups || []).map((t) => t.name))]],
            ['EC2 tag filters', (g.ec2TagFilters || []).map((f) => `${f.Key}=${f.Value ?? ''}`)],
            ['On-premises tag filters', (g.onPremisesInstanceTagFilters || []).map((f) => `${f.Key}=${f.Value ?? ''}`)],
            ['Auto rollback', g.autoRollbackConfiguration?.enabled ? (g.autoRollbackConfiguration.events || []).join(', ') : false],
            ['Alarms', g.alarmConfiguration?.enabled ? (g.alarmConfiguration.alarms || []).map((x) => x.name) : undefined],
            ['Blue/green termination', bg?.terminateBlueInstancesOnDeploymentSuccess ? `${bg.terminateBlueInstancesOnDeploymentSuccess.action} after ${bg.terminateBlueInstancesOnDeploymentSuccess.terminationWaitTimeInMinutes ?? 0} min` : undefined],
          ]),
          section('Last deployments', [
            ['Last attempted', g.lastAttemptedDeployment ? `${g.lastAttemptedDeployment.deploymentId} · ${g.lastAttemptedDeployment.status} · ${g.lastAttemptedDeployment.endTime?.toISOString() ?? ''}` : undefined],
            ['Last successful', g.lastSuccessfulDeployment ? `${g.lastSuccessfulDeployment.deploymentId} · ${g.lastSuccessfulDeployment.endTime?.toISOString() ?? ''}` : undefined],
            ['Target revision', revisionText(g.targetRevision)],
          ]),
        ],
        tables: [table(['Trigger', 'Events', 'SNS topic'], (g.triggerConfigurations || []).map((t) => [t.triggerName, t.triggerEvents, t.triggerTargetArn]), { title: 'Triggers', emptyMessage: 'No triggers' })],
      }),
      tab('Deployments', { tables: [deploymentTable(parts.deployments || [], false)] }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function configPage(c: CodeDeployClient, id: string, name: string): Promise<ResourcePage> {
  const d = (await c.send(new GetDeploymentConfigCommand({ deploymentConfigName: name }))).deploymentConfigInfo;
  if (!d) throw httpError(`Deployment configuration not found: ${name}`, 404);
  const t = d.trafficRoutingConfig;
  return {
    id,
    title: name,
    subtitle: `${d.computePlatform ?? ''} deployment configuration`,
    tabs: [
      tab('Details', {
        sections: [
          section('Configuration', [
            ['Compute platform', d.computePlatform],
            ['Minimum healthy hosts', d.minimumHealthyHosts ? `${d.minimumHealthyHosts.value} ${d.minimumHealthyHosts.type === 'FLEET_PERCENT' ? '%' : 'hosts'}` : undefined],
            ['Traffic routing', t?.type],
            ['Canary', t?.timeBasedCanary ? `${t.timeBasedCanary.canaryPercentage}% then the rest after ${t.timeBasedCanary.canaryInterval} min` : undefined],
            ['Linear', t?.timeBasedLinear ? `${t.timeBasedLinear.linearPercentage}% every ${t.timeBasedLinear.linearInterval} min` : undefined],
            ['Zonal', d.zonalConfig ? `wait ${d.zonalConfig.monitorDurationInSeconds ?? '-'} s per zone` : undefined],
            ['Created', d.createTime],
          ]),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'app') return appPage(c, profile, region, id, rest);
  if (kind === 'dg') return groupPage(c, profile, region, id, rest);
  if (kind === 'cfg') return configPage(c, id, rest);
  throw httpError(`Unknown CodeDeploy page: ${id}`, 400);
}

export const codeDeployAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (id.startsWith('cfg:') || !arn) throw httpError('Deployment configurations have no tags', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (id.startsWith('cfg:') || !arn) throw httpError('Deployment configurations have no tags', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('app:'),
};
