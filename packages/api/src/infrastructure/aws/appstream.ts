import {
  AppStreamClient,
  DescribeFleetsCommand,
  DescribeStacksCommand,
  ListAssociatedStacksCommand,
  ListAssociatedFleetsCommand,
  DescribeImageBuildersCommand,
  DescribeImagesCommand,
  DescribeSessionsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-appstream';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** AppStream 2.0: fleets, stacks, image builders and your own images. */
const client = (p: string, r: string) => new AppStreamClient(clientConfig(p, r));
const hours = (s?: number) => (s === undefined ? undefined : `${(s / 3600).toFixed(1)} h`);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [fleets, stacks, builders, images] = await Promise.all([
    pageAll((NextToken) => c.send(new DescribeFleetsCommand({ NextToken })), (r) => r.Fleets, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new DescribeStacksCommand({ NextToken })), (r) => r.Stacks, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeImageBuildersCommand({ NextToken })), (r) => r.ImageBuilders, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeImagesCommand({ NextToken, Type: 'PRIVATE' })), (r) => r.Images, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...fleets.map((f) => ({ id: `fleet:${f.Name}`, name: f.DisplayName || f.Name || '', group: 'Fleets', status: f.State, info: [f.FleetType, f.InstanceType, `${f.ComputeCapacityStatus?.InUse ?? 0}/${f.ComputeCapacityStatus?.Running ?? 0} in use`].join(' · ') })).sort(byName),
    ...stacks.map((s) => ({ id: `stack:${s.Name}`, name: s.DisplayName || s.Name || '', group: 'Stacks' })).sort(byName),
    ...builders.map((b) => ({ id: `builder:${b.Name}`, name: b.DisplayName || b.Name || '', group: 'Image builders', status: b.State, info: b.InstanceType })).sort(byName),
    ...images.map((i) => ({ id: `image:${i.Name}`, name: i.DisplayName || i.Name || '', group: 'My images', status: i.State, info: i.Platform })).sort(byName),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  const errors: string[] = [];
  const tags = async (arn?: string) => (arn ? (await settle({ t: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })) }, errors)).t?.Tags : undefined);
  if (kind === 'fleet') {
    const f = (await c.send(new DescribeFleetsCommand({ Names: [name] }))).Fleets?.[0];
    if (!f) throw httpError(`Fleet not found: ${name}`, 404);
    const parts = await settle({ stacks: pageAll((NextToken) => c.send(new ListAssociatedStacksCommand({ FleetName: name, NextToken })), (r) => r.Names, (r) => r.NextToken) }, errors);
    const cap = f.ComputeCapacityStatus;
    return {
      id,
      title: f.DisplayName || name,
      subtitle: `${f.FleetType ?? ''} fleet`,
      status: f.State,
      arn: f.Arn,
      tabs: [
        tab('Details', {
          sections: [
            section('Fleet', [['Type', f.FleetType], ['Instance type', f.InstanceType], ['Image', f.ImageName], ['Platform', f.Platform], ['Stacks', parts.stacks], ['Max session', hours(f.MaxUserDurationInSeconds)], ['Disconnect timeout (s)', f.DisconnectTimeoutInSeconds], ['Idle timeout (s)', f.IdleDisconnectTimeoutInSeconds], ['Internet access', f.EnableDefaultInternetAccess], ['Domain join', f.DomainJoinInfo?.DirectoryName], ['Subnets', f.VpcConfig?.SubnetIds], ['Role', f.IamRoleArn], ['Created', f.CreatedTime]]),
            section('Capacity', [['Desired', cap?.Desired], ['Running', cap?.Running], ['In use', cap?.InUse], ['Available', cap?.Available]]),
          ],
          tables: [table(['Code', 'Message'], (f.FleetErrors || []).map((e) => [e.ErrorCode, e.ErrorMessage]), { title: 'Errors', emptyMessage: 'No errors' })],
        }),
      ],
      tags: tagMap(await tags(f.Arn)),
      actions: [],
      errors,
    };
  }
  if (kind === 'stack') {
    const s = (await c.send(new DescribeStacksCommand({ Names: [name] }))).Stacks?.[0];
    if (!s) throw httpError(`Stack not found: ${name}`, 404);
    const parts = await settle({ fleets: pageAll((NextToken) => c.send(new ListAssociatedFleetsCommand({ StackName: name, NextToken })), (r) => r.Names, (r) => r.NextToken) }, errors);
    const fleet = parts.fleets?.[0];
    const sessions = fleet ? await pageAll((NextToken) => c.send(new DescribeSessionsCommand({ StackName: name, FleetName: fleet, NextToken })), (r) => r.Sessions, (r) => r.NextToken, 200).catch(() => []) : [];
    return {
      id,
      title: s.DisplayName || name,
      subtitle: 'AppStream stack',
      arn: s.Arn,
      tabs: [
        tab('Details', {
          sections: [section('Stack', [['Description', s.Description], ['Fleets', parts.fleets], ['Storage', (s.StorageConnectors || []).map((x) => x.ConnectorType)], ['Redirect URL', s.RedirectURL], ['Application settings persistence', s.ApplicationSettings?.Enabled], ['Embed host domains', s.EmbedHostDomains], ['Created', s.CreatedTime]])],
          tables: [
            table(['Setting', 'Permission'], (s.UserSettings || []).map((u) => [u.Action, u.Permission]), { title: 'User settings', emptyMessage: 'Defaults' }),
            table(['User', 'State', 'Started', 'Auth'], sessions.map((x) => [x.UserId, x.State, x.StartTime, x.AuthenticationType]), { title: fleet ? `Active sessions on ${fleet}` : 'Active sessions', statusColumn: 1, emptyMessage: 'No active sessions' }),
          ],
        }),
      ],
      tags: tagMap(await tags(s.Arn)),
      actions: [],
      errors,
    };
  }
  if (kind === 'builder' || kind === 'image') {
    if (kind === 'builder') {
      const b = (await c.send(new DescribeImageBuildersCommand({ Names: [name] }))).ImageBuilders?.[0];
      if (!b) throw httpError(`Image builder not found: ${name}`, 404);
      return { id, title: b.DisplayName || name, subtitle: 'Image builder', status: b.State, arn: b.Arn, tabs: [tab('Details', { sections: [section('Image builder', [['Instance type', b.InstanceType], ['Platform', b.Platform], ['Base image', lastPart(b.ImageArn)], ['State reason', b.StateChangeReason?.Message], ['Internet access', b.EnableDefaultInternetAccess], ['Subnets', b.VpcConfig?.SubnetIds], ['Created', b.CreatedTime]])] })], tags: tagMap(await tags(b.Arn)), actions: [], errors };
    }
    const i = (await c.send(new DescribeImagesCommand({ Names: [name] }))).Images?.[0];
    if (!i) throw httpError(`Image not found: ${name}`, 404);
    return {
      id,
      title: i.DisplayName || name,
      subtitle: 'AppStream image',
      status: i.State,
      arn: i.Arn,
      tabs: [tab('Details', { sections: [section('Image', [['Platform', i.Platform], ['Visibility', i.Visibility], ['Base image', lastPart(i.BaseImageArn)], ['Built by', i.ImageBuilderName], ['Agent version', i.AppstreamAgentVersion], ['Created', i.CreatedTime]])], tables: [table(['Application', 'Display name', 'Launch path'], (i.Applications || []).map((a) => [a.Name, a.DisplayName, a.LaunchPath]), { title: 'Applications', emptyMessage: 'No applications' })] })],
      tags: tagMap(await tags(i.Arn)),
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown AppStream page: ${id}`, 400);
}

export const appStreamAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('fleet:'),
};
