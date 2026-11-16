import {
  DirectoryServiceClient,
  DescribeDirectoriesCommand,
  DescribeDomainControllersCommand,
  DescribeTrustsCommand,
  DescribeSnapshotsCommand,
  DescribeSharedDirectoriesCommand,
  ListTagsForResourceCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  type DirectoryDescription,
} from '@aws-sdk/client-directory-service';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, accountId } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new DirectoryServiceClient({ region: r, credentials: cachedCredentials(p) });

const typeLabel = (d: DirectoryDescription) =>
  d.Type === 'MicrosoftAD' ? `AWS Managed Microsoft AD${d.Edition ? ` (${d.Edition})` : ''}` : d.Type === 'ADConnector' ? 'AD Connector' : d.Type === 'SimpleAD' ? 'Simple AD' : d.Type === 'SharedMicrosoftAD' ? 'Shared Microsoft AD' : d.Type;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const dirs = await pageAll((NextToken) => c.send(new DescribeDirectoriesCommand({ NextToken })), (r) => r.DirectoryDescriptions, (r) => r.NextToken);
  return dirs
    .map((d) => ({ id: d.DirectoryId || '', name: d.Name || d.DirectoryId || '', status: d.Stage, info: [d.DirectoryId, typeLabel(d), d.Size].filter(Boolean).join(' · ') }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const d = (await c.send(new DescribeDirectoriesCommand({ DirectoryIds: [id] }))).DirectoryDescriptions?.[0];
  if (!d) throw httpError(`Directory not found: ${id}`, 404);
  const errors: string[] = [];
  const isMsAd = d.Type === 'MicrosoftAD';
  const parts = await settle(
    {
      dcs: isMsAd ? pageAll((NextToken) => c.send(new DescribeDomainControllersCommand({ DirectoryId: id, NextToken })), (r) => r.DomainControllers, (r) => r.NextToken) : Promise.resolve([]),
      trusts: isMsAd ? pageAll((NextToken) => c.send(new DescribeTrustsCommand({ DirectoryId: id, NextToken })), (r) => r.Trusts, (r) => r.NextToken) : Promise.resolve([]),
      snapshots: d.Type !== 'ADConnector' && d.Type !== 'SharedMicrosoftAD' ? pageAll((NextToken) => c.send(new DescribeSnapshotsCommand({ DirectoryId: id, NextToken })), (r) => r.Snapshots, (r) => r.NextToken) : Promise.resolve([]),
      shared: isMsAd ? pageAll((NextToken) => c.send(new DescribeSharedDirectoriesCommand({ OwnerDirectoryId: id, NextToken })), (r) => r.SharedDirectories, (r) => r.NextToken) : Promise.resolve([]),
      tags: pageAll((NextToken) => c.send(new ListTagsForResourceCommand({ ResourceId: id, NextToken })), (r) => r.Tags, (r) => r.NextToken),
      account: accountId(profile, region),
    },
    errors,
  );
  const vpc = d.VpcSettings ?? d.ConnectSettings;
  const radius = d.RadiusSettings;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Directory', [
          ['Directory ID', d.DirectoryId],
          ['Directory DNS name', d.Name],
          ['NetBIOS name', d.ShortName],
          ['Type', typeLabel(d)],
          ['Size', d.Size],
          ['Description', d.Description],
          ['Status', d.Stage],
          ['Status reason', d.StageReason],
          ['Launched', d.LaunchTime],
          ['Last updated', d.StageLastUpdatedDateTime],
          ['OS version', d.OsVersion],
          ['Access URL', d.AccessUrl],
          ['Alias', d.Alias],
          ['IAM Identity Center / SSO', d.SsoEnabled],
          ['Desired domain controllers', d.DesiredNumberOfDomainControllers],
        ]),
        section('Networking', [
          ['VPC', vpc?.VpcId],
          ['Subnets', vpc?.SubnetIds],
          ['Availability zones', vpc?.AvailabilityZones],
          ['Security group', d.VpcSettings?.SecurityGroupId ?? d.ConnectSettings?.SecurityGroupId],
          ['DNS addresses', d.DnsIpAddrs],
          ['Connected directory DNS', d.ConnectSettings?.ConnectIps],
          ['Service account', d.ConnectSettings?.CustomerUserName],
        ]),
        // RadiusSettings also carries the shared secret - only these fields are read.
        section('RADIUS / MFA', [
          ['Status', d.RadiusStatus],
          ['Servers', radius?.RadiusServers],
          ['Port', radius?.RadiusPort],
          ['Protocol', radius?.AuthenticationProtocol],
        ]),
      ],
    }),
  ];
  if (isMsAd) {
    tabs.push(
      tab('Domain controllers', {
        tables: [
          table(['Domain controller', 'IP address', 'Availability zone', 'Subnet', 'Status', 'Launched'], (parts.dcs || []).map((x) => [x.DomainControllerId, x.DnsIpAddr, x.AvailabilityZone, x.SubnetId, x.Status, x.LaunchTime]), { statusColumn: 4, emptyMessage: 'No domain controllers' }),
        ],
      }),
      tab('Trusts', {
        tables: [
          table(['Remote domain', 'Direction', 'Type', 'Selective auth', 'State', 'Created'], (parts.trusts || []).map((x) => [x.RemoteDomainName, x.TrustDirection, x.TrustType, x.SelectiveAuth, x.TrustState, x.CreatedDateTime]), { statusColumn: 4, emptyMessage: 'No trust relationships' }),
        ],
      }),
      tab('Sharing', {
        tables: [
          table(['Shared with account', 'Shared directory', 'Method', 'Status', 'Created'], (parts.shared || []).map((x) => [x.SharedAccountId, x.SharedDirectoryId, x.ShareMethod, x.ShareStatus, x.CreatedDateTime]), { statusColumn: 3, emptyMessage: 'Not shared with other accounts' }),
        ],
      }),
    );
  }
  if (d.Type !== 'ADConnector' && d.Type !== 'SharedMicrosoftAD') {
    tabs.push(
      tab('Snapshots', {
        tables: [table(['Snapshot', 'Name', 'Type', 'Status', 'Started'], (parts.snapshots || []).map((x) => [x.SnapshotId, x.Name, x.Type, x.Status, x.StartTime]), { statusColumn: 3, emptyMessage: 'No snapshots' })],
      }),
    );
  }
  return {
    id,
    title: d.Name || id,
    subtitle: typeLabel(d),
    status: d.Stage,
    arn: parts.account ? `arn:aws:ds:${region}:${parts.account}:directory/${id}` : undefined,
    tabs,
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

export const directoryServiceAdapter: PageServiceAdapter = singleKind('dir', {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new AddTagsToResourceCommand({ ResourceId: id, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new RemoveTagsFromResourceCommand({ ResourceId: id, TagKeys: [key] }));
  },
});
