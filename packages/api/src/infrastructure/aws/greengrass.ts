import {
  GreengrassV2Client,
  ListCoreDevicesCommand,
  GetCoreDeviceCommand,
  ListInstalledComponentsCommand,
  ListEffectiveDeploymentsCommand,
  ListDeploymentsCommand,
  GetDeploymentCommand,
  ListComponentsCommand,
  DescribeComponentCommand,
  TagResourceCommand as GgTag,
  UntagResourceCommand as GgUntag,
} from '@aws-sdk/client-greengrassv2';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, lastPart, accountId, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** IoT Greengrass (V2). */
const gg = (p: string, r: string) => new GreengrassV2Client(clientConfig(p, r));
const coreArn = async (p: string, r: string, thing: string) => `arn:aws:greengrass:${r}:${await accountId(p, r)}:coreDevices:${thing}`;

export const greengrassAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = gg(profile, region);
    const [cores, deployments, components] = await Promise.all([
      pageAll((nextToken) => c.send(new ListCoreDevicesCommand({ nextToken })), (r) => r.coreDevices, (r) => r.nextToken),
      pageAll((nextToken) => c.send(new ListDeploymentsCommand({ nextToken, historyFilter: 'LATEST_ONLY' })), (r) => r.deployments, (r) => r.nextToken).catch(() => []),
      pageAll((nextToken) => c.send(new ListComponentsCommand({ nextToken, scope: 'PRIVATE' })), (r) => r.components, (r) => r.nextToken).catch(() => []),
    ]);
    return [
      ...cores.map((x) => ({ id: `core:${x.coreDeviceThingName}`, name: x.coreDeviceThingName || '', group: 'Core devices', status: x.status, info: x.lastStatusUpdateTimestamp && `updated ${x.lastStatusUpdateTimestamp.toISOString().slice(0, 16).replace('T', ' ')}` })).sort(byName),
      ...deployments.map((d) => ({ id: `dep:${d.deploymentId}`, name: d.deploymentName || d.deploymentId || '', group: 'Deployments', status: d.deploymentStatus, info: lastPart(d.targetArn) })).sort(byName),
      ...components.map((x) => ({ id: `comp:${x.arn}`, name: x.componentName || '', group: 'My components', info: x.latestVersion?.componentVersion && `v${x.latestVersion.componentVersion}` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = gg(profile, region);
    const [kind, rest] = splitId(id);
    const errors: string[] = [];
    if (kind === 'core') {
      const d = await c.send(new GetCoreDeviceCommand({ coreDeviceThingName: rest }));
      const parts = await settle(
        {
          installed: pageAll((nextToken) => c.send(new ListInstalledComponentsCommand({ coreDeviceThingName: rest, nextToken })), (r) => r.installedComponents, (r) => r.nextToken),
          deployments: pageAll((nextToken) => c.send(new ListEffectiveDeploymentsCommand({ coreDeviceThingName: rest, nextToken })), (r) => r.effectiveDeployments, (r) => r.nextToken),
        },
        errors,
      );
      return {
        id,
        title: rest,
        subtitle: 'Greengrass core device',
        status: d.status,
        arn: await coreArn(profile, region, rest),
        tabs: [
          tab('Details', {
            sections: [section('Core device', [['Status', d.status], ['Nucleus version', d.coreVersion], ['Platform', d.platform], ['Architecture', d.architecture], ['Last status update', d.lastStatusUpdateTimestamp]])],
            tables: [
              table(['Component', 'Version', 'State', 'Details', 'Changed'], (parts.installed || []).map((x) => [x.componentName, x.componentVersion, x.lifecycleState, x.lifecycleStateDetails, x.lastStatusChangeTimestamp]), { title: 'Installed components', statusColumn: 2, emptyMessage: 'No components reported' }),
              table(['Deployment', 'Status', 'Reason', 'Modified'], (parts.deployments || []).map((x) => [x.deploymentName, x.coreDeviceExecutionStatus, x.reason, x.modifiedTimestamp]), { title: 'Deployments on this device', statusColumn: 1, emptyMessage: 'No deployments' }),
            ],
          }),
        ],
        tags: tagMap(d.tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'dep') {
      const d = await c.send(new GetDeploymentCommand({ deploymentId: rest }));
      return {
        id,
        title: d.deploymentName || rest,
        subtitle: 'Greengrass deployment',
        status: d.deploymentStatus,
        tabs: [
          tab('Details', {
            sections: [section('Deployment', [['Target', d.targetArn], ['Status', d.deploymentStatus], ['Revision', d.revisionId], ['IoT job', d.iotJobId], ['Latest for target', d.isLatestForTarget], ['Created', d.creationTimestamp]])],
            tables: [table(['Component', 'Version'], Object.entries(d.components || {}).map(([k, v]) => [k, v.componentVersion]), { title: 'Components', emptyMessage: 'No components' })],
          }),
        ],
        tags: tagMap(d.tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'comp') {
      const versions = await pageAll((nextToken) => c.send(new ListComponentsCommand({ nextToken, scope: 'PRIVATE' })), (r) => r.components, (r) => r.nextToken);
      const latest = versions.find((x) => x.arn === rest)?.latestVersion;
      const d = latest?.arn ? await c.send(new DescribeComponentCommand({ arn: latest.arn })) : undefined;
      return {
        id,
        title: d?.componentName || lastPart(rest) || rest,
        subtitle: 'Greengrass component',
        status: d?.status?.componentState,
        arn: rest,
        tabs: [tab('Details', { sections: [section('Component', [['Latest version', d?.componentVersion], ['Publisher', d?.publisher], ['Description', d?.description], ['State', d?.status?.componentState], ['Platforms', (d?.platforms || []).map((p) => p.name || JSON.stringify(p.attributes))], ['Created', d?.creationTimestamp]])] })],
        tags: tagMap(d?.tags),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown Greengrass page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('This page has no taggable ARN', 400);
    await gg(profile, region).send(new GgTag({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('This page has no taggable ARN', 400);
    await gg(profile, region).send(new GgUntag({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('core:'),
};
