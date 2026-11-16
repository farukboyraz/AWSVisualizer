import {
  MediaLiveClient,
  ListChannelsCommand as MlListChannels,
  DescribeChannelCommand,
  ListInputsCommand,
  DescribeInputCommand,
  ListInputSecurityGroupsCommand,
  ListMultiplexesCommand,
  CreateTagsCommand as MlCreateTags,
  DeleteTagsCommand as MlDeleteTags,
} from '@aws-sdk/client-medialive';
import type { PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, tagMap, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** `rtmp://user:pass@host/app` → `rtmp://••••@host/app`. */
const noUserInfo = (url?: string) => url?.replace(/\/\/[^@/\s]+@/, '//••••@');

/** MediaLive. */
const ml = (p: string, r: string) => new MediaLiveClient(clientConfig(p, r));

export const mediaLiveAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = ml(profile, region);
    const [channels, inputs, sgs, multiplexes] = await Promise.all([
      pageAll((NextToken) => c.send(new MlListChannels({ NextToken })), (r) => r.Channels, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListInputsCommand({ NextToken })), (r) => r.Inputs, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListInputSecurityGroupsCommand({ NextToken })), (r) => r.InputSecurityGroups, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListMultiplexesCommand({ NextToken })), (r) => r.Multiplexes, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      ...channels.map((x) => ({ id: `ch:${x.Id}`, name: x.Name || x.Id || '', group: 'Channels', status: x.State, info: [x.ChannelClass, `${x.PipelinesRunningCount ?? 0} pipelines running`].join(' · ') })).sort(byName),
      ...inputs.map((x) => ({ id: `in:${x.Id}`, name: x.Name || x.Id || '', group: 'Inputs', status: x.State, info: [x.Type, x.InputClass].filter(Boolean).join(' · ') })).sort(byName),
      ...sgs.map((x) => ({ id: `sg:${x.Id}`, name: x.Id || '', group: 'Input security groups', status: x.State, info: (x.WhitelistRules || []).map((w) => w.Cidr).join(', ') })),
      ...multiplexes.map((x) => ({ id: `mx:${x.Id}`, name: x.Name || x.Id || '', group: 'Multiplexes', status: x.State, info: `${x.ProgramCount ?? 0} programs` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = ml(profile, region);
    const [kind, rest] = splitId(id);
    if (kind === 'ch') {
      const x = await c.send(new DescribeChannelCommand({ ChannelId: rest }));
      // Destinations: URL (credentials stripped) and stream name only - passwords live in SSM parameters.
      const dests = (x.Destinations || []).flatMap((d) => [
        ...(d.Settings || []).map((s) => [d.Id, noUserInfo(s.Url), s.StreamName]),
        ...(d.MediaPackageSettings || []).map((m) => [d.Id, `MediaPackage ${m.ChannelId}`, undefined]),
      ]);
      const tabs: PageTab[] = [
        tab('Details', {
          sections: [section('Channel', [['State', x.State], ['Class', x.ChannelClass], ['Pipelines running', x.PipelinesRunningCount], ['Input codec', x.InputSpecification && `${x.InputSpecification.Codec} · ${x.InputSpecification.Resolution} · ${x.InputSpecification.MaximumBitrate}`], ['Inputs', (x.InputAttachments || []).map((a) => a.InputAttachmentName ?? a.InputId)], ['Log level', x.LogLevel], ['Maintenance window', x.Maintenance?.MaintenanceDay && `${x.Maintenance.MaintenanceDay} ${x.Maintenance.MaintenanceStartTime ?? ''}`], ['Role', x.RoleArn]])],
          tables: [
            table(['Destination', 'URL', 'Stream'], dests, { title: 'Destinations', emptyMessage: 'No destinations' }),
            table(['Output group', 'Type', 'Outputs'], (x.EncoderSettings?.OutputGroups || []).map((g) => [g.Name, Object.keys(g.OutputGroupSettings || {}).find((k) => (g.OutputGroupSettings as Record<string, unknown>)[k])?.replace('GroupSettings', ''), (g.Outputs || []).length]), { title: 'Output groups', emptyMessage: 'No output groups' }),
            table(['Pipeline', 'Active input', 'Active motion graphics'], (x.PipelineDetails || []).map((p) => [p.PipelineId, p.ActiveInputAttachmentName, p.ActiveMotionGraphicsUri]), { title: 'Pipelines', emptyMessage: 'Channel not running' }),
          ],
        }),
      ];
      return { id, title: x.Name || rest, subtitle: `MediaLive ${x.ChannelClass ?? ''} channel`, status: x.State, arn: x.Arn, tabs, tags: tagMap(x.Tags), actions: [], errors: [] };
    }
    if (kind === 'in') {
      const x = await c.send(new DescribeInputCommand({ InputId: rest }));
      return {
        id,
        title: x.Name || rest,
        subtitle: `${x.Type ?? ''} input`,
        status: x.State,
        arn: x.Arn,
        tabs: [
          tab('Details', {
            sections: [section('Input', [['Type', x.Type], ['Class', x.InputClass], ['State', x.State], ['Source type', x.InputSourceType], ['Attached channels', x.AttachedChannels], ['Security groups', x.SecurityGroups], ['MediaConnect flows', (x.MediaConnectFlows || []).map((f) => lastPart(f.FlowArn))], ['Role', x.RoleArn]])],
            tables: [
              table(['Endpoint', 'IP', 'Port'], (x.Destinations || []).map((d) => [noUserInfo(d.Url), d.Ip, d.Port]), { title: 'Push endpoints', emptyMessage: 'Not a push input' }),
              table(['Pull source', 'Username'], (x.Sources || []).map((s) => [noUserInfo(s.Url), s.Username]), { title: 'Pull sources', emptyMessage: 'Not a pull input' }),
            ],
          }),
        ],
        tags: tagMap(x.Tags),
        actions: [],
        errors: [],
      };
    }
    if (kind === 'sg' || kind === 'mx') {
      const all = kind === 'sg' ? await pageAll((NextToken) => c.send(new ListInputSecurityGroupsCommand({ NextToken })), (r) => r.InputSecurityGroups, (r) => r.NextToken) : await pageAll((NextToken) => c.send(new ListMultiplexesCommand({ NextToken })), (r) => r.Multiplexes, (r) => r.NextToken);
      const x = all.find((i) => i.Id === rest) as { Id?: string; Arn?: string; State?: string; Tags?: Record<string, string>; WhitelistRules?: { Cidr?: string }[]; Inputs?: string[]; Name?: string; ProgramCount?: number; AvailabilityZones?: string[] } | undefined;
      if (!x) throw httpError(`Not found: ${rest}`, 404);
      return {
        id,
        title: x.Name || rest,
        subtitle: kind === 'sg' ? 'Input security group' : 'Multiplex',
        status: x.State,
        arn: x.Arn,
        tabs: [tab('Details', { sections: [section(kind === 'sg' ? 'Security group' : 'Multiplex', kind === 'sg' ? [['Allowed CIDRs', (x.WhitelistRules || []).map((w) => w.Cidr)], ['Inputs', x.Inputs]] : [['Programs', x.ProgramCount], ['Availability Zones', x.AvailabilityZones]])] })],
        tags: tagMap(x.Tags),
        actions: [],
        errors: [],
      };
    }
    throw httpError(`Unknown MediaLive page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await ml(profile, region).send(new MlCreateTags({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await ml(profile, region).send(new MlDeleteTags({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('ch:'),
};
