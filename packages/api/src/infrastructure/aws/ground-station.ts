import {
  GroundStationClient,
  ListConfigsCommand,
  ListMissionProfilesCommand,
  GetMissionProfileCommand,
  ListContactsCommand,
  ListGroundStationsCommand,
  ListDataflowEndpointGroupsCommand,
  ListSatellitesCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-groundstation';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Ground Station: mission profiles, configs, dataflow endpoint groups, satellites and a contacts page (past and next 7 days). */
const client = (p: string, r: string) => new GroundStationClient(clientConfig(p, r));
const DAY = 86_400_000;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [profiles, configs, endpoints, satellites] = await Promise.all([
    pageAll((nextToken) => c.send(new ListMissionProfilesCommand({ nextToken })), (r) => r.missionProfileList, (r) => r.nextToken),
    pageAll((nextToken) => c.send(new ListConfigsCommand({ nextToken })), (r) => r.configList, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => c.send(new ListDataflowEndpointGroupsCommand({ nextToken })), (r) => r.dataflowEndpointGroupList, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => c.send(new ListSatellitesCommand({ nextToken })), (r) => r.satellites, (r) => r.nextToken).catch(() => []),
  ]);
  return [
    { id: 'contacts:', name: 'Contacts', group: 'Schedule', info: 'Past 7 and next 7 days' },
    ...profiles.map((p) => ({ id: `mp:${p.missionProfileId}`, name: p.name || '', group: 'Mission profiles', info: p.region })).sort(byName),
    ...configs.map((x) => ({ id: `cfg:${x.configType}|${x.configId}`, name: x.name || '', group: 'Configs', info: x.configType })).sort(byName),
    ...endpoints.map((e) => ({ id: `deg:${e.dataflowEndpointGroupId}`, name: e.dataflowEndpointGroupId || '', group: 'Dataflow endpoint groups' })),
    ...satellites.map((s) => ({ id: `sat:${s.satelliteId}`, name: `NORAD ${s.noradSatelliteID}`, group: 'Onboarded satellites', info: (s.groundStations || []).join(', ') })),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];
  if (kind === 'contacts') {
    const now = Date.now();
    const [contacts, stations] = await Promise.all([
      pageAll((nextToken) => c.send(new ListContactsCommand({ nextToken, startTime: new Date(now - 7 * DAY), endTime: new Date(now + 7 * DAY), statusList: ['SCHEDULED', 'SCHEDULING', 'PASS', 'COMPLETED', 'FAILED', 'CANCELLED', 'AWS_FAILED', 'FAILED_TO_SCHEDULE', 'PREPASS', 'POSTPASS'] })), (r) => r.contactList, (r) => r.nextToken),
      pageAll((nextToken) => c.send(new ListGroundStationsCommand({ nextToken })), (r) => r.groundStationList, (r) => r.nextToken).catch(() => []),
    ]);
    return {
      id,
      title: 'Contacts',
      subtitle: 'Past 7 and next 7 days',
      tabs: [
        tab('Contacts', { tables: [table(['Start', 'End', 'Status', 'Ground station', 'Satellite', 'Mission profile', 'Max elevation', 'Error'], contacts.sort((a, b) => (a.startTime?.getTime() ?? 0) - (b.startTime?.getTime() ?? 0)).map((x) => [x.startTime, x.endTime, x.contactStatus, x.groundStation, lastPart(x.satelliteArn), lastPart(x.missionProfileArn), x.maximumElevation?.value !== undefined ? `${x.maximumElevation.value.toFixed(1)}°` : undefined, x.errorMessage]), { statusColumn: 2, emptyMessage: 'No contacts in this window' })] }),
        tab('Ground stations', { tables: [table(['Ground station', 'Region'], stations.map((s) => [s.groundStationName, s.region]), { emptyMessage: 'None available' })] }),
      ],
      actions: [],
      errors,
    };
  }
  if (kind === 'mp') {
    const p = await c.send(new GetMissionProfileCommand({ missionProfileId: rest }));
    const { tags } = await settle({ tags: p.missionProfileArn ? c.send(new ListTagsForResourceCommand({ resourceArn: p.missionProfileArn })) : Promise.resolve(undefined) }, errors);
    return {
      id,
      title: p.name || rest,
      subtitle: 'Mission profile',
      arn: p.missionProfileArn,
      tabs: [
        tab('Details', {
          sections: [section('Mission profile', [['Tracking config', lastPart(p.trackingConfigArn)], ['Minimum contact (s)', p.minimumViableContactDurationSeconds], ['Pre-pass (s)', p.contactPrePassDurationSeconds], ['Post-pass (s)', p.contactPostPassDurationSeconds], ['Streams KMS key', p.streamsKmsKey?.kmsKeyArn], ['Region', p.region]])],
          tables: [table(['From', 'To'], (p.dataflowEdges || []).map((e) => [lastPart(e[0]), lastPart(e[1])]), { title: 'Dataflow edges', emptyMessage: 'No dataflow edges' })],
        }),
      ],
      tags: tagMap(tags?.tags),
      actions: [],
      errors,
    };
  }
  if (kind === 'cfg' || kind === 'deg' || kind === 'sat') {
    const label = kind === 'cfg' ? 'Config' : kind === 'deg' ? 'Dataflow endpoint group' : 'Satellite';
    return { id, title: rest.split('|').pop() || rest, subtitle: label, tabs: [tab('Details', { sections: [section(label, [['ID', rest.split('|').pop()], ['Type', kind === 'cfg' ? rest.split('|')[0] : undefined]], { note: 'Open the Ground Station console for the full definition.' })] })], actions: [], errors };
  }
  throw httpError(`Unknown Ground Station page: ${id}`, 400);
}

export const groundStationAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !id.startsWith('mp:')) throw httpError('Only mission profiles can be tagged here', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !id.startsWith('mp:')) throw httpError('Only mission profiles can be tagged here', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('mp:'),
};
