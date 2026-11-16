import {
  MediaPackageClient,
  ListChannelsCommand as MpListChannels,
  DescribeChannelCommand as MpDescribeChannel,
  ListOriginEndpointsCommand,
  TagResourceCommand as MpTag,
  UntagResourceCommand as MpUntag,
} from '@aws-sdk/client-mediapackage';
import {
  MediaPackageV2Client,
  ListChannelGroupsCommand,
  ListChannelsCommand as Mp2ListChannels,
  ListOriginEndpointsCommand as Mp2ListOriginEndpoints,
  TagResourceCommand as Mp2Tag,
  UntagResourceCommand as Mp2Untag,
  ListTagsForResourceCommand as Mp2ListTags,
} from '@aws-sdk/client-mediapackagev2';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, mapLimited, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** MediaPackage (v1 + v2). */
const mp = (p: string, r: string) => new MediaPackageClient(clientConfig(p, r));
const mp2 = (p: string, r: string) => new MediaPackageV2Client(clientConfig(p, r));

export const mediaPackageAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const [v1, groups] = await Promise.all([
      pageAll((NextToken) => mp(profile, region).send(new MpListChannels({ NextToken })), (r) => r.Channels, (r) => r.NextToken),
      pageAll((NextToken) => mp2(profile, region).send(new ListChannelGroupsCommand({ NextToken })), (r) => r.Items, (r) => r.NextToken).catch(() => []),
    ]);
    const v2 = (await mapLimited(groups, 4, (g) => pageAll((NextToken) => mp2(profile, region).send(new Mp2ListChannels({ ChannelGroupName: g.ChannelGroupName, NextToken })), (r) => r.Items, (r) => r.NextToken).catch(() => []))).flat();
    return [
      ...v1.map((x) => ({ id: `ch:${x.Id}`, name: x.Id || '', group: 'Channels (v1)', info: x.Description })).sort(byName),
      ...v2.map((x) => ({ id: `ch2:${x.ChannelGroupName}|${x.ChannelName}`, name: `${x.ChannelGroupName} / ${x.ChannelName}`, group: 'Channels (v2)', info: x.InputType ?? x.Description })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const [kind, rest] = splitId(id);
    if (kind === 'ch') {
      const c = mp(profile, region);
      const x = await c.send(new MpDescribeChannel({ Id: rest }));
      const endpoints = await pageAll((NextToken) => c.send(new ListOriginEndpointsCommand({ ChannelId: rest, NextToken })), (r) => r.OriginEndpoints, (r) => r.NextToken).catch(() => []);
      const format = (e: (typeof endpoints)[number]) => (e.HlsPackage ? 'HLS' : e.DashPackage ? 'DASH' : e.CmafPackage ? 'CMAF' : e.MssPackage ? 'MSS' : '-');
      return {
        id,
        title: rest,
        subtitle: 'MediaPackage channel',
        arn: x.Arn,
        tabs: [
          tab('Details', {
            sections: [
              // Ingest endpoints: URLs only - their WebDAV usernames / passwords are never shown.
              section('Channel', [['Description', x.Description], ['Ingest access logs', x.IngressAccessLogs?.LogGroupName], ['Egress access logs', x.EgressAccessLogs?.LogGroupName], ['Created', x.CreatedAt]]),
              { title: 'Ingest endpoints', settings: [], copyable: (x.HlsIngest?.IngestEndpoints || []).map((e, i) => ({ label: `Endpoint ${i + 1}`, value: e.Url || '-' })) },
            ],
            tables: [table(['Origin endpoint', 'Format', 'Origination', 'Startover (s)', 'Allowlist', 'URL'], endpoints.map((e) => [e.Id, format(e), e.Origination, e.StartoverWindowSeconds, e.Whitelist, e.Url]), { title: 'Origin endpoints', emptyMessage: 'No origin endpoints' })],
          }),
        ],
        tags: tagMap(x.Tags),
        actions: [],
        errors: [],
      };
    }
    if (kind === 'ch2') {
      const i = rest.indexOf('|');
      const [group, name] = [rest.slice(0, i), rest.slice(i + 1)];
      const c = mp2(profile, region);
      const channels = await pageAll((NextToken) => c.send(new Mp2ListChannels({ ChannelGroupName: group, NextToken })), (r) => r.Items, (r) => r.NextToken);
      const ch = channels.find((x) => x.ChannelName === name);
      if (!ch) throw httpError(`Channel not found: ${rest}`, 404);
      const errors: string[] = [];
      const parts = await settle({ endpoints: pageAll((NextToken) => c.send(new Mp2ListOriginEndpoints({ ChannelGroupName: group, ChannelName: name, NextToken })), (r) => r.Items, (r) => r.NextToken), tags: c.send(new Mp2ListTags({ ResourceArn: ch.Arn })) }, errors);
      return {
        id,
        title: `${group} / ${name}`,
        subtitle: 'MediaPackage v2 channel',
        arn: ch.Arn,
        tabs: [
          tab('Details', {
            sections: [section('Channel', [['Channel group', group], ['Input type', ch.InputType], ['Description', ch.Description], ['Created', ch.CreatedAt], ['Modified', ch.ModifiedAt]])],
            tables: [table(['Origin endpoint', 'Container', 'HLS manifests', 'DASH manifests', 'Modified'], (parts.endpoints || []).map((e) => [e.OriginEndpointName, e.ContainerType, (e.HlsManifests || []).map((m) => m.Url ?? m.ManifestName), (e.DashManifests || []).map((m) => m.Url ?? m.ManifestName), e.ModifiedAt]), { title: 'Origin endpoints', emptyMessage: 'No origin endpoints' })],
          }),
        ],
        tags: tagMap(parts.tags?.Tags),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown MediaPackage page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    if (id.startsWith('ch2:')) await mp2(profile, region).send(new Mp2Tag({ ResourceArn: arn, Tags: { [key]: value } }));
    else await mp(profile, region).send(new MpTag({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    if (id.startsWith('ch2:')) await mp2(profile, region).send(new Mp2Untag({ ResourceArn: arn, TagKeys: [key] }));
    else await mp(profile, region).send(new MpUntag({ ResourceArn: arn, TagKeys: [key] }));
  },
};
