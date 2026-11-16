import {
  LaunchWizardClient,
  ListDeploymentsCommand,
  GetDeploymentCommand,
  ListDeploymentEventsCommand,
  ListWorkloadsCommand,
  GetWorkloadCommand,
  ListWorkloadDeploymentPatternsCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-launch-wizard';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new LaunchWizardClient({ region: r, credentials: cachedCredentials(p) });

/** Deployment specifications carry the passwords entered in the wizard; those keys are never output. */
const SECRET_KEY = /pass(word)?|secret|token|credential|private.?key|\bkey\b|pwd/i;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [deployments, workloads] = await Promise.all([
    pageAll((nextToken) => c.send(new ListDeploymentsCommand({ nextToken })), (r) => r.deployments, (r) => r.nextToken),
    pageAll((nextToken) => c.send(new ListWorkloadsCommand({ nextToken })), (r) => r.workloads, (r) => r.nextToken).catch(() => []),
  ]);
  return [
    ...deployments
      .filter((d) => d.status !== 'DELETED')
      .map((d) => ({ id: `dep:${d.id}`, name: d.name || d.id || '', group: 'Deployments', status: d.status, info: [d.workloadName, d.patternName].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    ...workloads.map((w) => ({ id: `wl:${w.workloadName}`, name: w.displayName || w.workloadName || '', group: 'Available workloads', info: w.workloadName })).sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function deploymentPage(c: LaunchWizardClient, id: string, deploymentId: string): Promise<ResourcePage> {
  const d = (await c.send(new GetDeploymentCommand({ deploymentId }))).deployment;
  if (!d) throw httpError(`Deployment not found: ${deploymentId}`, 404);
  const errors: string[] = [];
  const { events } = await settle({ events: pageAll((nextToken) => c.send(new ListDeploymentEventsCommand({ deploymentId, nextToken })), (r) => r.deploymentEvents, (r) => r.nextToken) }, errors);
  const specs = Object.entries(d.specifications || {});
  const hidden = specs.filter(([k]) => SECRET_KEY.test(k)).length;
  return {
    id,
    title: d.name || deploymentId,
    subtitle: [d.workloadName, d.patternName].filter(Boolean).join(' · '),
    status: d.status,
    arn: d.deploymentArn,
    tabs: [
      tab('Details', {
        sections: [section('Deployment', [['ID', d.id], ['Workload', d.workloadName], ['Pattern', d.patternName], ['Status', d.status], ['Resource group', d.resourceGroup], ['Created', d.createdAt], ['Deleted', d.deletedAt]])],
      }),
      tab('Specifications', {
        tables: [
          table(
            ['Setting', 'Value'],
            specs.filter(([k]) => !SECRET_KEY.test(k)).sort((a, b) => a[0].localeCompare(b[0])),
            { title: hidden ? `${hidden} password / secret settings hidden` : undefined, emptyMessage: 'No specifications' },
          ),
        ],
      }),
      tab('Events', {
        tables: [table(['Time', 'Step', 'Status', 'Reason', 'Description'], (events || []).sort((a, b) => (b.timestamp?.getTime() ?? 0) - (a.timestamp?.getTime() ?? 0)).map((e) => [e.timestamp, e.name, e.status, e.statusReason, e.description]), { statusColumn: 2, emptyMessage: 'No events' })],
      }),
    ],
    tags: tagMap(d.tags),
    actions: [],
    errors,
  };
}

async function workloadPage(c: LaunchWizardClient, id: string, workloadName: string): Promise<ResourcePage> {
  const w = (await c.send(new GetWorkloadCommand({ workloadName }))).workload;
  if (!w) throw httpError(`Workload not found: ${workloadName}`, 404);
  const errors: string[] = [];
  const { patterns } = await settle({ patterns: pageAll((nextToken) => c.send(new ListWorkloadDeploymentPatternsCommand({ workloadName, nextToken })), (r) => r.workloadDeploymentPatterns, (r) => r.nextToken) }, errors);
  return {
    id,
    title: w.displayName || workloadName,
    subtitle: 'Launch Wizard workload',
    status: w.status,
    tabs: [
      tab('Details', {
        sections: [section('Workload', [['Name', w.workloadName], ['Description', w.description], ['Status', w.status], ['Status message', w.statusMessage], ['Documentation', w.documentationUrl]])],
        tables: [table(['Pattern', 'Version', 'Status', 'Description'], (patterns || []).map((p) => [p.displayName || p.deploymentPatternName, p.workloadVersionName, p.status, p.description]), { title: 'Deployment patterns', statusColumn: 2, emptyMessage: 'No patterns' })],
      }),
    ],
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'dep') return deploymentPage(c, id, rest);
  if (kind === 'wl') return workloadPage(c, id, rest);
  throw httpError(`Unknown Launch Wizard page: ${id}`, 400);
}

function deploymentArn(id: string, arn: string) {
  if (!id.startsWith('dep:') || !arn) throw httpError('Only deployments can be tagged', 400);
  return arn;
}

export const launchWizardAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ resourceArn: deploymentArn(id, arn), tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: deploymentArn(id, arn), tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('dep:'),
};
