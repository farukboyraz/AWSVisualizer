import {
  IoTSiteWiseClient,
  ListAssetModelsCommand,
  DescribeAssetModelCommand,
  ListAssetsCommand,
  DescribeAssetCommand,
  ListAssociatedAssetsCommand,
  ListGatewaysCommand,
  DescribeGatewayCommand,
  ListPortalsCommand,
  DescribePortalCommand,
  ListTagsForResourceCommand as SwListTags,
  TagResourceCommand as SwTag,
  UntagResourceCommand as SwUntag,
} from '@aws-sdk/client-iotsitewise';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, mapLimited, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** IoT SiteWise. */
const sw = (p: string, r: string) => new IoTSiteWiseClient(clientConfig(p, r));

export const siteWiseAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = sw(profile, region);
    const [models, gateways, portals] = await Promise.all([
      pageAll((nextToken) => c.send(new ListAssetModelsCommand({ nextToken })), (r) => r.assetModelSummaries, (r) => r.nextToken),
      pageAll((nextToken) => c.send(new ListGatewaysCommand({ nextToken })), (r) => r.gatewaySummaries, (r) => r.nextToken).catch(() => []),
      pageAll((nextToken) => c.send(new ListPortalsCommand({ nextToken })), (r) => r.portalSummaries, (r) => r.nextToken).catch(() => []),
    ]);
    const assets = await pageAll((nextToken) => c.send(new ListAssetsCommand({ nextToken, filter: 'TOP_LEVEL' })), (r) => r.assetSummaries, (r) => r.nextToken, 500).catch(() => []);
    return [
      ...models.map((m) => ({ id: `model:${m.id}`, name: m.name || '', group: 'Asset models', status: m.status?.state, info: m.assetModelType })).sort(byName),
      ...assets.map((a) => ({ id: `asset:${a.id}`, name: a.name || '', group: 'Top-level assets', status: a.status?.state })).sort(byName),
      ...gateways.map((g) => ({ id: `gw:${g.gatewayId}`, name: g.gatewayName || '', group: 'Gateways', info: g.gatewayPlatform?.greengrassV2 ? 'Greengrass V2' : g.gatewayPlatform?.siemensIE ? 'Siemens Industrial Edge' : undefined })).sort(byName),
      ...portals.map((p) => ({ id: `portal:${p.id}`, name: p.name || '', group: 'Portals', status: p.status?.state })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = sw(profile, region);
    const [kind, rest] = splitId(id);
    const errors: string[] = [];
    const tags = async (arn?: string) => (arn ? (await settle({ t: c.send(new SwListTags({ resourceArn: arn })) }, errors)).t?.tags : undefined);
    if (kind === 'model') {
      const m = await c.send(new DescribeAssetModelCommand({ assetModelId: rest }));
      return {
        id,
        title: m.assetModelName || rest,
        subtitle: 'Asset model',
        status: m.assetModelStatus?.state,
        arn: m.assetModelArn,
        tabs: [
          tab('Details', {
            sections: [section('Asset model', [['Type', m.assetModelType], ['Description', m.assetModelDescription], ['Status', m.assetModelStatus?.state], ['Created', m.assetModelCreationDate], ['Updated', m.assetModelLastUpdateDate]])],
            tables: [
              table(['Property', 'Kind', 'Data type', 'Unit'], (m.assetModelProperties || []).map((p) => [p.name, p.type?.measurement ? 'Measurement' : p.type?.metric ? 'Metric' : p.type?.transform ? 'Transform' : p.type?.attribute ? 'Attribute' : '-', p.dataType, p.unit]), { title: 'Properties', emptyMessage: 'No properties' }),
              table(['Hierarchy', 'Child model'], (m.assetModelHierarchies || []).map((h) => [h.name, h.childAssetModelId]), { title: 'Hierarchies', emptyMessage: 'No hierarchies' }),
            ],
          }),
        ],
        tags: tagMap(await tags(m.assetModelArn)),
        actions: [],
        errors,
      };
    }
    if (kind === 'asset') {
      const a = await c.send(new DescribeAssetCommand({ assetId: rest }));
      const children = (await mapLimited(a.assetHierarchies || [], 3, (h) => pageAll((nextToken) => c.send(new ListAssociatedAssetsCommand({ assetId: rest, hierarchyId: h.id, nextToken })), (r) => r.assetSummaries, (r) => r.nextToken).then((xs) => xs.map((x) => [h.name, x.name, x.status?.state])).catch(() => []))).flat();
      return {
        id,
        title: a.assetName || rest,
        subtitle: 'Asset',
        status: a.assetStatus?.state,
        arn: a.assetArn,
        tabs: [
          tab('Details', {
            sections: [section('Asset', [['Model', a.assetModelId], ['Description', a.assetDescription], ['Status', a.assetStatus?.state], ['Created', a.assetCreationDate], ['Updated', a.assetLastUpdateDate]])],
            tables: [
              table(['Property', 'Alias', 'Data type', 'Unit', 'Notifications'], (a.assetProperties || []).map((p) => [p.name, p.alias, p.dataType, p.unit, p.notification?.state]), { title: 'Properties', emptyMessage: 'No properties' }),
              table(['Hierarchy', 'Child asset', 'Status'], children, { title: 'Child assets', emptyMessage: 'No child assets' }),
            ],
          }),
        ],
        tags: tagMap(await tags(a.assetArn)),
        actions: [],
        errors,
      };
    }
    if (kind === 'gw') {
      const g = await c.send(new DescribeGatewayCommand({ gatewayId: rest }));
      return {
        id,
        title: g.gatewayName || rest,
        subtitle: 'SiteWise gateway',
        arn: g.gatewayArn,
        tabs: [
          tab('Details', {
            sections: [section('Gateway', [['Platform', g.gatewayPlatform?.greengrassV2 ? `Greengrass V2 · ${g.gatewayPlatform.greengrassV2.coreDeviceThingName}` : g.gatewayPlatform?.siemensIE ? 'Siemens Industrial Edge' : '-'], ['Created', g.creationDate], ['Updated', g.lastUpdateDate]])],
            tables: [table(['Capability', 'Sync status'], (g.gatewayCapabilitySummaries || []).map((x) => [x.capabilityNamespace, x.capabilitySyncStatus]), { title: 'Capabilities', statusColumn: 1, emptyMessage: 'No capabilities' })],
          }),
        ],
        tags: tagMap(await tags(g.gatewayArn)),
        actions: [],
        errors,
      };
    }
    if (kind === 'portal') {
      const p = await c.send(new DescribePortalCommand({ portalId: rest }));
      return {
        id,
        title: p.portalName || rest,
        subtitle: 'SiteWise Monitor portal',
        status: p.portalStatus?.state,
        arn: p.portalArn,
        tabs: [
          tab('Details', {
            sections: [
              section('Portal', [['Status', p.portalStatus?.state], ['Auth mode', p.portalAuthMode], ['Contact email', p.portalContactEmail], ['Description', p.portalDescription], ['Role', p.roleArn], ['Created', p.portalCreationDate]]),
              ...(p.portalStartUrl ? [{ title: 'Portal', settings: [], copyable: [{ label: 'Start URL', value: p.portalStartUrl }] }] : []),
            ],
          }),
        ],
        tags: tagMap(await tags(p.portalArn)),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown SiteWise page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await sw(profile, region).send(new SwTag({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await sw(profile, region).send(new SwUntag({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('asset:') || row.id.startsWith('model:'),
};
