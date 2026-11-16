import {
  LocationClient,
  ListMapsCommand,
  DescribeMapCommand,
  ListPlaceIndexesCommand,
  DescribePlaceIndexCommand,
  ListRouteCalculatorsCommand,
  DescribeRouteCalculatorCommand,
  ListTrackersCommand,
  DescribeTrackerCommand,
  ListTrackerConsumersCommand,
  ListGeofenceCollectionsCommand,
  DescribeGeofenceCollectionCommand,
  ListGeofencesCommand,
  ListKeysCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-location';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/**
 * Amazon Location Service: maps, place indexes, route calculators,
 * trackers, geofence collections and API keys (names / restrictions only -
 * the key values are never read).
 */
const client = (p: string, r: string) => new LocationClient(clientConfig(p, r));

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [maps, places, routes, trackers, geofences, keys] = await Promise.all([
    pageAll((NextToken) => c.send(new ListMapsCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListPlaceIndexesCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListRouteCalculatorsCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListTrackersCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListGeofenceCollectionsCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListKeysCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...maps.map((m) => ({ id: `map:${m.MapName}`, name: m.MapName || '', group: 'Maps', info: m.DataSource })).sort(byName),
    ...places.map((p) => ({ id: `place:${p.IndexName}`, name: p.IndexName || '', group: 'Place indexes', info: p.DataSource })).sort(byName),
    ...routes.map((r) => ({ id: `route:${r.CalculatorName}`, name: r.CalculatorName || '', group: 'Route calculators', info: r.DataSource })).sort(byName),
    ...trackers.map((t) => ({ id: `tracker:${t.TrackerName}`, name: t.TrackerName || '', group: 'Trackers', info: t.Description })).sort(byName),
    ...geofences.map((g) => ({ id: `geo:${g.CollectionName}`, name: g.CollectionName || '', group: 'Geofence collections', info: g.Description })).sort(byName),
    ...keys.map((k) => ({ id: `key:${k.KeyName}`, name: k.KeyName || '', group: 'API keys', status: k.ExpireTime && k.ExpireTime.getTime() < Date.now() ? 'EXPIRED' : 'ACTIVE', info: k.ExpireTime && `expires ${k.ExpireTime.toISOString().slice(0, 10)}` })).sort(byName),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  const errors: string[] = [];
  const page = (subtitle: string, arn: string | undefined, pairs: [string, unknown][], tags?: Record<string, string>, tables: ResourcePage['tabs'][number]['tables'] = []): ResourcePage => ({
    id,
    title: name,
    subtitle,
    arn,
    tabs: [tab('Details', { sections: [section(subtitle, pairs)], tables })],
    tags: tagMap(tags),
    actions: [],
    errors,
  });
  if (kind === 'map') {
    const m = await c.send(new DescribeMapCommand({ MapName: name }));
    return page('Map', m.MapArn, [['Data source', m.DataSource], ['Style', m.Configuration?.Style], ['Political view', m.Configuration?.PoliticalView], ['Description', m.Description], ['Created', m.CreateTime], ['Updated', m.UpdateTime]], m.Tags);
  }
  if (kind === 'place') {
    const p = await c.send(new DescribePlaceIndexCommand({ IndexName: name }));
    return page('Place index', p.IndexArn, [['Data source', p.DataSource], ['Storage of results', p.DataSourceConfiguration?.IntendedUse], ['Description', p.Description], ['Created', p.CreateTime], ['Updated', p.UpdateTime]], p.Tags);
  }
  if (kind === 'route') {
    const r = await c.send(new DescribeRouteCalculatorCommand({ CalculatorName: name }));
    return page('Route calculator', r.CalculatorArn, [['Data source', r.DataSource], ['Description', r.Description], ['Created', r.CreateTime], ['Updated', r.UpdateTime]], r.Tags);
  }
  if (kind === 'tracker') {
    const t = await c.send(new DescribeTrackerCommand({ TrackerName: name }));
    const { consumers } = await settle({ consumers: pageAll((NextToken) => c.send(new ListTrackerConsumersCommand({ TrackerName: name, NextToken })), (r) => r.ConsumerArns, (r) => r.NextToken) }, errors);
    return page('Tracker', t.TrackerArn, [['Position filtering', t.PositionFiltering], ['Linked geofence collections', (consumers || []).map(lastPart)], ['EventBridge events', t.EventBridgeEnabled], ['KMS key', t.KmsKeyId], ['Description', t.Description], ['Created', t.CreateTime]], t.Tags);
  }
  if (kind === 'geo') {
    const g = await c.send(new DescribeGeofenceCollectionCommand({ CollectionName: name }));
    const { fences } = await settle({ fences: pageAll((NextToken) => c.send(new ListGeofencesCommand({ CollectionName: name, NextToken })), (r) => r.Entries, (r) => r.NextToken, 500) }, errors);
    return page('Geofence collection', g.CollectionArn, [['Geofences', g.GeofenceCount], ['KMS key', g.KmsKeyId], ['Description', g.Description], ['Created', g.CreateTime], ['Updated', g.UpdateTime]], g.Tags, [
      table(['Geofence', 'Status', 'Shape', 'Updated'], (fences || []).map((f) => [f.GeofenceId, f.Status, f.Geometry?.Circle ? `circle ${f.Geometry.Circle.Radius} m` : f.Geometry?.Polygon ? `polygon (${f.Geometry.Polygon[0]?.length ?? 0} points)` : '-', f.UpdateTime]), { title: 'Geofences', statusColumn: 1, emptyMessage: 'No geofences' }),
    ]);
  }
  if (kind === 'key') {
    const k = (await pageAll((NextToken) => c.send(new ListKeysCommand({ NextToken })), (r) => r.Entries, (r) => r.NextToken)).find((x) => x.KeyName === name);
    if (!k) throw httpError(`API key not found: ${name}`, 404);
    return page('API key', undefined, [['Expires', k.ExpireTime], ['Allowed actions', k.Restrictions?.AllowActions], ['Allowed resources', k.Restrictions?.AllowResources], ['Allowed referers', k.Restrictions?.AllowReferers], ['Description', k.Description], ['Created', k.CreateTime]]);
  }
  throw httpError(`Unknown Location page: ${id}`, 400);
}

export const locationAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('This resource has no tags here', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('This resource has no tags here', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => !row.id.startsWith('key:'),
};
