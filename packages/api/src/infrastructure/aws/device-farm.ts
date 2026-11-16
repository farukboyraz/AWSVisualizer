import {
  DeviceFarmClient,
  ListProjectsCommand,
  GetProjectCommand,
  ListRunsCommand,
  ListDevicePoolsCommand,
  ListTestGridProjectsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-device-farm';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Device Farm only exists in us-west-2, whatever region is selected. */
const client = (p: string) => new DeviceFarmClient(clientConfig(p, 'us-west-2'));

async function list(profile: string): Promise<PageSummary[]> {
  const c = client(profile);
  const [projects, grids] = await Promise.all([
    pageAll((nextToken) => c.send(new ListProjectsCommand({ nextToken })), (r) => r.projects, (r) => r.nextToken),
    pageAll((nextToken) => c.send(new ListTestGridProjectsCommand({ nextToken })), (r) => r.testGridProjects, (r) => r.nextToken).catch(() => []),
  ]);
  return [
    ...projects.map((p) => ({ id: `proj:${p.arn}`, name: p.name || '', group: 'Mobile device testing', info: p.created && `created ${p.created.toISOString().slice(0, 10)}` })).sort(byName),
    ...grids.map((g) => ({ id: `grid:${g.arn}`, name: g.name || '', group: 'Desktop browser testing', info: g.description })).sort(byName),
  ];
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const c = client(profile);
  const [kind, arn] = splitId(id);
  const errors: string[] = [];
  const tags = async () => (await settle({ t: c.send(new ListTagsForResourceCommand({ ResourceARN: arn })) }, errors)).t?.Tags;
  if (kind === 'proj') {
    const p = (await c.send(new GetProjectCommand({ arn }))).project;
    if (!p) throw httpError(`Project not found: ${arn}`, 404);
    const parts = await settle(
      {
        runs: pageAll((nextToken) => c.send(new ListRunsCommand({ arn, nextToken })), (r) => r.runs, (r) => r.nextToken, 50),
        pools: pageAll((nextToken) => c.send(new ListDevicePoolsCommand({ arn, type: 'PRIVATE', nextToken })), (r) => r.devicePools, (r) => r.nextToken),
      },
      errors,
    );
    return {
      id,
      title: p.name || arn,
      subtitle: 'Device Farm project (us-west-2)',
      arn,
      tabs: [
        tab('Runs', {
          tables: [
            table(['Run', 'Platform', 'Type', 'Status', 'Result', 'Passed / failed', 'Device minutes', 'Created'], (parts.runs || []).map((r) => [r.name, r.platform, r.type, r.status, r.result, `${r.counters?.passed ?? 0} / ${r.counters?.failed ?? 0}`, r.deviceMinutes?.total, r.created]), {
              statusColumn: 4,
              title: 'Last 50 runs',
              emptyMessage: 'No runs',
            }),
          ],
        }),
        tab('Details', {
          sections: [section('Project', [['Default job timeout (min)', p.defaultJobTimeoutMinutes], ['VPC', p.vpcConfig?.vpcId], ['Created', p.created]])],
          tables: [table(['Device pool', 'Description', 'Max devices'], (parts.pools || []).map((x) => [x.name, x.description, x.maxDevices]), { title: 'My device pools', emptyMessage: 'No private device pools' })],
        }),
      ],
      tags: tagList(await tags()),
      actions: [],
      errors,
    };
  }
  if (kind === 'grid') {
    const grids = await pageAll((nextToken) => c.send(new ListTestGridProjectsCommand({ nextToken })), (r) => r.testGridProjects, (r) => r.nextToken);
    const g = grids.find((x) => x.arn === arn);
    if (!g) throw httpError(`Test grid project not found: ${arn}`, 404);
    return { id, title: g.name || arn, subtitle: 'Desktop browser testing project', arn, tabs: [tab('Details', { sections: [section('Project', [['Description', g.description], ['VPC', g.vpcConfig?.vpcId], ['Created', g.created]])] })], tags: tagList(await tags()), actions: [], errors };
  }
  throw httpError(`Unknown Device Farm page: ${id}`, 400);
}

export const deviceFarmAdapter: PageServiceAdapter = {
  list: (profile) => list(profile),
  detail,
  async addTag(profile, _region, id, _arn, key, value) {
    await client(profile).send(new TagResourceCommand({ ResourceARN: splitId(id)[1], Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, _region, id, _arn, key) {
    await client(profile).send(new UntagResourceCommand({ ResourceARN: splitId(id)[1], TagKeys: [key] }));
  },
};
