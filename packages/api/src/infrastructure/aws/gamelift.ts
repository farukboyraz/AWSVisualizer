import {
  GameLiftClient,
  ListFleetsCommand,
  DescribeFleetAttributesCommand,
  DescribeFleetCapacityCommand,
  DescribeFleetLocationAttributesCommand,
  ListBuildsCommand,
  ListScriptsCommand,
  ListAliasesCommand,
  DescribeGameSessionQueuesCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-gamelift';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/**
 * GameLift: fleets (capacity, locations), builds, scripts, aliases and
 * game session queues. Server launch parameters are not shown (they can
 * carry secrets passed to the game server).
 */
const client = (p: string, r: string) => new GameLiftClient(clientConfig(p, r));
const size = (b?: number) => (b === undefined ? undefined : `${(b / 1e6).toFixed(1)} MB`);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [fleetIds, builds, scripts, aliases, queues] = await Promise.all([
    pageAll((NextToken) => c.send(new ListFleetsCommand({ NextToken })), (r) => r.FleetIds, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListBuildsCommand({ NextToken })), (r) => r.Builds, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListScriptsCommand({ NextToken })), (r) => r.Scripts, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListAliasesCommand({ NextToken })), (r) => r.Aliases, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeGameSessionQueuesCommand({ NextToken })), (r) => r.GameSessionQueues, (r) => r.NextToken).catch(() => []),
  ]);
  const chunks = Array.from({ length: Math.ceil(fleetIds.length / 50) }, (_, i) => fleetIds.slice(i * 50, i * 50 + 50));
  const fleets = (await mapLimited(chunks, 3, (FleetIds) => c.send(new DescribeFleetAttributesCommand({ FleetIds })).then((r) => r.FleetAttributes || []))).flat();
  return [
    ...fleets.map((f) => ({ id: `fleet:${f.FleetId}`, name: f.Name || f.FleetId || '', group: 'Fleets', status: f.Status, info: [f.ComputeType, f.FleetType, f.InstanceType].filter(Boolean).join(' · ') })).sort(byName),
    ...aliases.map((a) => ({ id: `alias:${a.AliasId}`, name: a.Name || '', group: 'Aliases', info: a.RoutingStrategy?.Type })).sort(byName),
    ...queues.map((q) => ({ id: `queue:${q.Name}`, name: q.Name || '', group: 'Game session queues', info: `${q.Destinations?.length ?? 0} destinations` })).sort(byName),
    ...builds.map((b) => ({ id: `build:${b.BuildId}`, name: `${b.Name ?? b.BuildId} ${b.Version ?? ''}`.trim(), group: 'Builds', status: b.Status, info: b.OperatingSystem })).sort(byName),
    ...scripts.map((s) => ({ id: `script:${s.ScriptId}`, name: `${s.Name ?? s.ScriptId} ${s.Version ?? ''}`.trim(), group: 'Realtime scripts' })).sort(byName),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];
  const tags = async (arn?: string) => (arn ? (await settle({ t: c.send(new ListTagsForResourceCommand({ ResourceARN: arn })) }, errors)).t?.Tags : undefined);
  if (kind === 'fleet') {
    const f = (await c.send(new DescribeFleetAttributesCommand({ FleetIds: [rest] }))).FleetAttributes?.[0];
    if (!f) throw httpError(`Fleet not found: ${rest}`, 404);
    const parts = await settle({ cap: c.send(new DescribeFleetCapacityCommand({ FleetIds: [rest] })), locations: c.send(new DescribeFleetLocationAttributesCommand({ FleetId: rest })) }, errors);
    const cap = parts.cap?.FleetCapacity?.[0]?.InstanceCounts;
    return {
      id,
      title: f.Name || rest,
      subtitle: `${f.ComputeType ?? 'EC2'} fleet`,
      status: f.Status,
      arn: f.FleetArn,
      tabs: [
        tab('Details', {
          sections: [
            section('Fleet', [['Fleet ID', f.FleetId], ['Compute', f.ComputeType], ['Type', f.FleetType], ['Instance type', f.InstanceType], ['Operating system', f.OperatingSystem], ['Build', f.BuildId], ['Script', f.ScriptId], ['Protection', f.NewGameSessionProtectionPolicy], ['Metric groups', f.MetricGroups], ['Server launch path', f.ServerLaunchPath], ['Role', f.InstanceRoleArn], ['Created', f.CreationTime]]),
            section('Capacity (home region)', [['Desired', cap?.DESIRED], ['Active', cap?.ACTIVE], ['Idle', cap?.IDLE], ['Pending', cap?.PENDING], ['Min / max', cap ? `${cap.MINIMUM ?? 0} / ${cap.MAXIMUM ?? 0}` : undefined]]),
          ],
          tables: [table(['Location', 'Status', 'Stopped actions'], (parts.locations?.LocationAttributes || []).map((l) => [l.LocationState?.Location, l.LocationState?.Status, l.StoppedActions]), { title: 'Locations', statusColumn: 1, emptyMessage: 'Home region only' })],
        }),
      ],
      tags: tagList(await tags(f.FleetArn)),
      actions: [],
      errors,
    };
  }
  const one = async <T extends object>(items: T[], pick: (x: T) => boolean): Promise<T> => {
    const x = items.find(pick);
    if (!x) throw httpError(`Not found: ${rest}`, 404);
    return x;
  };
  if (kind === 'alias') {
    const a = await one(await pageAll((NextToken) => c.send(new ListAliasesCommand({ NextToken })), (r) => r.Aliases, (r) => r.NextToken), (x) => x.AliasId === rest);
    return { id, title: a.Name || rest, subtitle: 'Alias', arn: a.AliasArn, tabs: [tab('Details', { sections: [section('Alias', [['Routing', a.RoutingStrategy?.Type], ['Fleet', a.RoutingStrategy?.FleetId], ['Message', a.RoutingStrategy?.Message], ['Description', a.Description], ['Created', a.CreationTime]])] })], tags: tagList(await tags(a.AliasArn)), actions: [], errors };
  }
  if (kind === 'queue') {
    const q = (await c.send(new DescribeGameSessionQueuesCommand({ Names: [rest] }))).GameSessionQueues?.[0];
    if (!q) throw httpError(`Queue not found: ${rest}`, 404);
    return {
      id,
      title: rest,
      subtitle: 'Game session queue',
      arn: q.GameSessionQueueArn,
      tabs: [
        tab('Details', {
          sections: [section('Queue', [['Timeout (s)', q.TimeoutInSeconds], ['Allowed locations', q.FilterConfiguration?.AllowedLocations], ['Priority order', q.PriorityConfiguration?.PriorityOrder], ['Notifications', q.NotificationTarget]])],
          tables: [
            table(['Destination'], (q.Destinations || []).map((d) => [d.DestinationArn]), { title: 'Destinations', emptyMessage: 'No destinations' }),
            table(['Max latency (ms)', 'For (s)'], (q.PlayerLatencyPolicies || []).map((p) => [p.MaximumIndividualPlayerLatencyMilliseconds, p.PolicyDurationSeconds]), { title: 'Player latency policies', emptyMessage: 'None' }),
          ],
        }),
      ],
      tags: tagList(await tags(q.GameSessionQueueArn)),
      actions: [],
      errors,
    };
  }
  if (kind === 'build') {
    const b = await one(await pageAll((NextToken) => c.send(new ListBuildsCommand({ NextToken })), (r) => r.Builds, (r) => r.NextToken), (x) => x.BuildId === rest);
    return { id, title: `${b.Name ?? rest} ${b.Version ?? ''}`.trim(), subtitle: 'Build', status: b.Status, arn: b.BuildArn, tabs: [tab('Details', { sections: [section('Build', [['Status', b.Status], ['Operating system', b.OperatingSystem], ['Size', size(b.SizeOnDisk)], ['Server SDK', b.ServerSdkVersion], ['Created', b.CreationTime]])] })], tags: tagList(await tags(b.BuildArn)), actions: [], errors };
  }
  if (kind === 'script') {
    const s = await one(await pageAll((NextToken) => c.send(new ListScriptsCommand({ NextToken })), (r) => r.Scripts, (r) => r.NextToken), (x) => x.ScriptId === rest);
    return { id, title: `${s.Name ?? rest} ${s.Version ?? ''}`.trim(), subtitle: 'Realtime script', arn: s.ScriptArn, tabs: [tab('Details', { sections: [section('Script', [['Size', size(s.SizeOnDisk)], ['Storage', s.StorageLocation && `s3://${s.StorageLocation.Bucket}/${s.StorageLocation.Key}`], ['Created', s.CreationTime]])] })], tags: tagList(await tags(s.ScriptArn)), actions: [], errors };
  }
  throw httpError(`Unknown GameLift page: ${id}`, 400);
}

export const gameLiftAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('fleet:'),
};
