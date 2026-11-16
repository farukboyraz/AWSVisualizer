import {
  WorkSpacesClient,
  DescribeWorkspacesCommand,
  DescribeWorkspaceDirectoriesCommand,
  DescribeWorkspaceBundlesCommand,
  DescribeTagsCommand,
  CreateTagsCommand,
  DeleteTagsCommand,
} from '@aws-sdk/client-workspaces';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** WorkSpaces: virtual desktops, their directories and your own bundles. */
const client = (p: string, r: string) => new WorkSpacesClient(clientConfig(p, r));
const WORKSPACE_LIMIT = 1000;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [workspaces, directories, bundles] = await Promise.all([
    pageAll((NextToken) => c.send(new DescribeWorkspacesCommand({ NextToken })), (r) => r.Workspaces, (r) => r.NextToken, WORKSPACE_LIMIT),
    pageAll((NextToken) => c.send(new DescribeWorkspaceDirectoriesCommand({ NextToken })), (r) => r.Directories, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeWorkspaceBundlesCommand({ NextToken })), (r) => r.Bundles, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...workspaces.map((w) => ({ id: `ws:${w.WorkspaceId}`, name: w.WorkspaceName || w.ComputerName || w.WorkspaceId || '', group: 'WorkSpaces', status: w.State, info: [w.UserName, w.WorkspaceProperties?.ComputeTypeName, w.WorkspaceProperties?.RunningMode].filter(Boolean).join(' · ') })).sort(byName),
    ...directories.map((d) => ({ id: `dir:${d.DirectoryId}`, name: d.DirectoryName || d.DirectoryId || '', group: 'Directories', status: d.State, info: d.DirectoryType })).sort(byName),
    ...bundles.map((b) => ({ id: `bundle:${b.BundleId}`, name: b.Name || b.BundleId || '', group: 'My bundles', status: b.State, info: b.ComputeType?.Name })).sort(byName),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];
  const tags = async () => (await settle({ t: c.send(new DescribeTagsCommand({ ResourceId: rest })) }, errors)).t?.TagList;
  if (kind === 'ws') {
    const w = (await c.send(new DescribeWorkspacesCommand({ WorkspaceIds: [rest] }))).Workspaces?.[0];
    if (!w) throw httpError(`WorkSpace not found: ${rest}`, 404);
    const p = w.WorkspaceProperties;
    return {
      id,
      title: w.WorkspaceName || w.ComputerName || rest,
      subtitle: `WorkSpace of ${w.UserName ?? '-'}`,
      status: w.State,
      tabs: [
        tab('Details', {
          sections: [
            section('WorkSpace', [['WorkSpace ID', w.WorkspaceId], ['User', w.UserName], ['State', w.State], ['Error', w.ErrorMessage], ['Computer name', w.ComputerName], ['IP address', w.IpAddress], ['Directory', w.DirectoryId], ['Bundle', w.BundleId], ['Subnet', w.SubnetId]]),
            section('Properties', [['Compute', p?.ComputeTypeName], ['Running mode', p?.RunningMode], ['Auto-stop (min)', p?.RunningModeAutoStopTimeoutInMinutes], ['Root volume (GiB)', p?.RootVolumeSizeGib], ['User volume (GiB)', p?.UserVolumeSizeGib], ['Protocols', p?.Protocols], ['Operating system', p?.OperatingSystemName], ['Volume encryption', w.RootVolumeEncryptionEnabled || w.UserVolumeEncryptionEnabled ? w.VolumeEncryptionKey ?? 'Enabled' : false]]),
          ],
        }),
      ],
      tags: tagList(await tags()),
      actions: [],
      errors,
    };
  }
  if (kind === 'dir') {
    // The registration code is left out - it lets clients connect to the directory.
    const d = (await c.send(new DescribeWorkspaceDirectoriesCommand({ DirectoryIds: [rest] }))).Directories?.[0];
    if (!d) throw httpError(`Directory not found: ${rest}`, 404);
    const wcp = d.WorkspaceCreationProperties;
    return {
      id,
      title: d.DirectoryName || rest,
      subtitle: `${d.DirectoryType ?? ''} directory`,
      status: d.State,
      tabs: [
        tab('Details', {
          sections: [
            section('Directory', [['Directory ID', d.DirectoryId], ['Alias', d.Alias], ['Type', d.DirectoryType], ['State', d.State], ['Subnets', d.SubnetIds], ['DNS servers', d.DnsIpAddresses], ['Service account', d.CustomerUserName], ['Security group', d.WorkspaceSecurityGroupId], ['IP groups', d.ipGroupIds], ['Tenancy', d.Tenancy]]),
            section('Defaults for new WorkSpaces', [['Internet access', wcp?.EnableInternetAccess], ['User is local admin', wcp?.UserEnabledAsLocalAdministrator], ['Maintenance mode', wcp?.EnableMaintenanceMode], ['Default OU', wcp?.DefaultOu], ['Custom security group', wcp?.CustomSecurityGroupId]]),
          ],
        }),
      ],
      tags: tagList(await tags()),
      actions: [],
      errors,
    };
  }
  if (kind === 'bundle') {
    const b = (await c.send(new DescribeWorkspaceBundlesCommand({ BundleIds: [rest] }))).Bundles?.[0];
    if (!b) throw httpError(`Bundle not found: ${rest}`, 404);
    return {
      id,
      title: b.Name || rest,
      subtitle: 'WorkSpaces bundle',
      status: b.State,
      tabs: [tab('Details', { sections: [section('Bundle', [['Description', b.Description], ['Compute', b.ComputeType?.Name], ['Root storage', b.RootStorage?.Capacity && `${b.RootStorage.Capacity} GiB`], ['User storage', b.UserStorage?.Capacity && `${b.UserStorage.Capacity} GiB`], ['Image', b.ImageId], ['Type', b.BundleType], ['Created', b.CreationTime], ['Updated', b.LastUpdatedTime]])] })],
      tags: tagList(await tags()),
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown WorkSpaces page: ${id}`, 400);
}

export const workSpacesAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new CreateTagsCommand({ ResourceId: splitId(id)[1], Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new DeleteTagsCommand({ ResourceId: splitId(id)[1], TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('ws:'),
};
