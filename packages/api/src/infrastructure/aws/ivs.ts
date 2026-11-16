import {
  IvsClient,
  ListChannelsCommand as IvsListChannels,
  GetChannelCommand,
  ListStreamKeysCommand,
  ListRecordingConfigurationsCommand,
  GetRecordingConfigurationCommand,
  ListStreamsCommand,
  ListStreamSessionsCommand,
  TagResourceCommand as IvsTag,
  UntagResourceCommand as IvsUntag,
} from '@aws-sdk/client-ivs';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Interactive Video Service. */
const ivs = (p: string, r: string) => new IvsClient(clientConfig(p, r));

export const ivsAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = ivs(profile, region);
    const [channels, recordings, live] = await Promise.all([
      pageAll((nextToken) => c.send(new IvsListChannels({ nextToken })), (r) => r.channels, (r) => r.nextToken),
      pageAll((nextToken) => c.send(new ListRecordingConfigurationsCommand({ nextToken })), (r) => r.recordingConfigurations, (r) => r.nextToken).catch(() => []),
      pageAll((nextToken) => c.send(new ListStreamsCommand({ nextToken })), (r) => r.streams, (r) => r.nextToken).catch(() => []),
    ]);
    const liveSet = new Set(live.map((s) => s.channelArn));
    return [
      ...channels.map((x) => ({ id: `ch:${x.arn}`, name: x.name || lastPart(x.arn) || '', group: 'Channels', status: liveSet.has(x.arn) ? 'LIVE' : 'OFFLINE', info: [x.type, x.latencyMode, x.authorized && 'private'].filter(Boolean).join(' · ') })).sort(byName),
      ...recordings.map((r) => ({ id: `rec:${r.arn}`, name: r.name || lastPart(r.arn) || '', group: 'Recording configurations', status: r.state, info: r.destinationConfiguration?.s3?.bucketName })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = ivs(profile, region);
    const [kind, arn] = splitId(id);
    const errors: string[] = [];
    if (kind === 'ch') {
      const x = (await c.send(new GetChannelCommand({ arn }))).channel;
      if (!x) throw httpError(`Channel not found: ${arn}`, 404);
      // Stream key values (GetStreamKey) and the SRT passphrase are never read or shown.
      const parts = await settle(
        {
          keys: pageAll((nextToken) => c.send(new ListStreamKeysCommand({ channelArn: arn, nextToken })), (r) => r.streamKeys, (r) => r.nextToken),
          sessions: c.send(new ListStreamSessionsCommand({ channelArn: arn, maxResults: 25 })),
        },
        errors,
      );
      return {
        id,
        title: x.name || lastPart(arn) || arn,
        subtitle: `${x.type ?? ''} IVS channel`,
        arn,
        tabs: [
          tab('Details', {
            sections: [
              section('Channel', [['Type', x.type], ['Latency', x.latencyMode], ['Transcode preset', x.preset], ['Private (playback auth)', x.authorized], ['Insecure ingest (RTMP)', x.insecureIngest], ['Recording', lastPart(x.recordingConfigurationArn)], ['Playback restriction policy', lastPart(x.playbackRestrictionPolicyArn)], ['Stream keys', parts.keys?.length]]),
              {
                title: 'Endpoints',
                settings: [],
                copyable: [
                  x.ingestEndpoint && { label: 'Ingest server', value: `rtmps://${x.ingestEndpoint}:443/app/` },
                  x.srt?.endpoint && { label: 'SRT endpoint', value: x.srt.endpoint },
                  x.playbackUrl && { label: 'Playback URL', value: x.playbackUrl },
                ].filter((e): e is { label: string; value: string } => Boolean(e)),
              },
            ],
            tables: [table(['Session', 'Started', 'Ended', 'Errors'], (parts.sessions?.streamSessions || []).map((s) => [s.streamId, s.startTime, s.endTime, s.hasErrorEvent ? 'Yes' : 'No']), { title: 'Recent stream sessions', emptyMessage: 'Never streamed' })],
          }),
        ],
        tags: tagMap(x.tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'rec') {
      const r = (await c.send(new GetRecordingConfigurationCommand({ arn }))).recordingConfiguration;
      if (!r) throw httpError(`Recording configuration not found: ${arn}`, 404);
      return {
        id,
        title: r.name || lastPart(arn) || arn,
        subtitle: 'Recording configuration',
        status: r.state,
        arn,
        tabs: [tab('Details', { sections: [section('Recording', [['State', r.state], ['Bucket', r.destinationConfiguration?.s3?.bucketName], ['Thumbnails', r.thumbnailConfiguration?.recordingMode], ['Reconnect window (s)', r.recordingReconnectWindowSeconds], ['Renditions', r.renditionConfiguration?.renditionSelection]])] })],
        tags: tagMap(r.tags),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown IVS page: ${id}`, 400);
  },
  async addTag(profile, region, id, _arn, key, value) {
    await ivs(profile, region).send(new IvsTag({ resourceArn: splitId(id)[1], tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await ivs(profile, region).send(new IvsUntag({ resourceArn: splitId(id)[1], tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('ch:'),
};
