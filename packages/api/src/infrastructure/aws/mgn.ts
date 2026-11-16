import {
  MgnClient,
  DescribeSourceServersCommand,
  ListApplicationsCommand,
  ListWavesCommand,
  TagResourceCommand as MgnTag,
  UntagResourceCommand as MgnUntag,
} from '@aws-sdk/client-mgn';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, tagMap, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const errName = (err: unknown) => (err as { name?: string })?.name || '';
/** Home-region services (Migration Hub, Discovery) and not-initialized services answer with these outside their setup. */
const notSetUp = (err: unknown) =>
  ['HomeRegionNotSetException', 'AccessDeniedException', 'UninitializedAccountException', 'InvalidInputException', 'AuthorizationErrorException'].includes(errName(err)) ||
  /home region|not (been )?initialized|not subscribed/i.test((err as { message?: string })?.message || '');
const quiet = <T>(p: Promise<T[]>) => p.catch((err) => (notSetUp(err) ? ([] as T[]) : Promise.reject(err)));
const bytes = (b?: number) => (b === undefined ? undefined : b >= 1e12 ? `${(b / 1e12).toFixed(2)} TB` : b >= 1e9 ? `${(b / 1e9).toFixed(2)} GB` : `${(b / 1e6).toFixed(1)} MB`);

/** Application Migration Service (MGN). */
const mgn = (p: string, r: string) => new MgnClient(clientConfig(p, r));

export const mgnAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = mgn(profile, region);
    const [servers, apps, waves] = await Promise.all([
      quiet(pageAll((nextToken) => c.send(new DescribeSourceServersCommand({ nextToken, filters: { isArchived: false } })), (r) => r.items, (r) => r.nextToken)),
      quiet(pageAll((nextToken) => c.send(new ListApplicationsCommand({ nextToken, filters: { isArchived: false } })), (r) => r.items, (r) => r.nextToken)),
      quiet(pageAll((nextToken) => c.send(new ListWavesCommand({ nextToken, filters: { isArchived: false } })), (r) => r.items, (r) => r.nextToken)),
    ]);
    return [
      ...servers.map((s) => ({ id: `src:${s.sourceServerID}`, name: s.sourceProperties?.identificationHints?.hostname || s.sourceServerID || '', group: 'Source servers', status: s.lifeCycle?.state, info: [s.dataReplicationInfo?.dataReplicationState, s.sourceProperties?.os?.fullString].filter(Boolean).join(' · ') })).sort(byName),
      ...apps.map((a) => ({ id: `app:${a.applicationID}`, name: a.name || '', group: 'Applications', status: a.applicationAggregatedStatus?.progressStatus, info: `${a.applicationAggregatedStatus?.totalSourceServers ?? 0} servers` })).sort(byName),
      ...waves.map((w) => ({ id: `wave:${w.waveID}`, name: w.name || '', group: 'Waves', status: w.waveAggregatedStatus?.progressStatus, info: `${w.waveAggregatedStatus?.totalApplications ?? 0} applications` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = mgn(profile, region);
    const [kind, rest] = splitId(id);
    if (kind === 'src') {
      const s = (await c.send(new DescribeSourceServersCommand({ filters: { sourceServerIDs: [rest] } }))).items?.[0];
      if (!s) throw httpError(`Source server not found: ${rest}`, 404);
      const sp = s.sourceProperties;
      const rep = s.dataReplicationInfo;
      const lc = s.lifeCycle;
      return {
        id,
        title: sp?.identificationHints?.hostname || rest,
        subtitle: 'Source server',
        status: lc?.state,
        arn: s.arn,
        tabs: [
          tab('Details', {
            sections: [
              section('Server', [['Source server ID', s.sourceServerID], ['Hostname', sp?.identificationHints?.hostname], ['FQDN', sp?.identificationHints?.fqdn], ['OS', sp?.os?.fullString], ['CPUs', (sp?.cpus || []).length], ['RAM', bytes(sp?.ramBytes)], ['Recommended instance', sp?.recommendedInstanceType], ['Application', s.applicationID], ['Replication type', s.replicationType]]),
              section('Lifecycle', [['State', lc?.state], ['Added', lc?.addedToServiceDateTime], ['Last seen', lc?.lastSeenByServiceDateTime], ['Last test', lc?.lastTest?.initiated?.jobID], ['Last cutover', lc?.lastCutover?.initiated?.jobID], ['Launched instance', s.launchedInstance?.ec2InstanceID]]),
              section('Replication', [['State', rep?.dataReplicationState], ['Lag', rep?.lagDuration], ['ETA', rep?.etaDateTime], ['Last snapshot', rep?.lastSnapshotDateTime], ['Error', rep?.dataReplicationError?.error]]),
            ],
            tables: [table(['Disk', 'Size', 'Replicated', 'Backlog'], (rep?.replicatedDisks || []).map((d) => [d.deviceName, bytes(d.totalStorageBytes), bytes(d.replicatedStorageBytes), bytes(d.backloggedStorageBytes)]), { title: 'Disks', emptyMessage: 'No disks' })],
          }),
        ],
        tags: tagMap(s.tags),
        actions: [],
        errors: [],
      };
    }
    if (kind === 'app' || kind === 'wave') {
      const items =
        kind === 'app'
          ? await pageAll((nextToken) => c.send(new ListApplicationsCommand({ nextToken, filters: { applicationIDs: [rest] } })), (r) => r.items, (r) => r.nextToken)
          : await pageAll((nextToken) => c.send(new ListWavesCommand({ nextToken, filters: { waveIDs: [rest] } })), (r) => r.items, (r) => r.nextToken);
      const x = items[0] as { name?: string; arn?: string; description?: string; creationDateTime?: string; lastModifiedDateTime?: string; tags?: Record<string, string>; waveID?: string } | undefined;
      if (!x) throw httpError(`Not found: ${rest}`, 404);
      return {
        id,
        title: x.name || rest,
        subtitle: kind === 'app' ? 'MGN application' : 'MGN wave',
        arn: x.arn,
        tabs: [tab('Details', { sections: [section(kind === 'app' ? 'Application' : 'Wave', [['ID', rest], ['Description', x.description], ['Wave', x.waveID], ['Created', x.creationDateTime], ['Modified', x.lastModifiedDateTime]])] })],
        tags: tagMap(x.tags),
        actions: [],
        errors: [],
      };
    }
    throw httpError(`Unknown MGN page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await mgn(profile, region).send(new MgnTag({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await mgn(profile, region).send(new MgnUntag({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('src:'),
};
