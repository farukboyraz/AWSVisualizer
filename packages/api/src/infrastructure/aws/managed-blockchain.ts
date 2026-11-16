import {
  ManagedBlockchainClient,
  ListNetworksCommand,
  GetNetworkCommand,
  ListMembersCommand,
  GetMemberCommand,
  ListNodesCommand,
  ListAccessorsCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-managedblockchain';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Managed Blockchain: Hyperledger Fabric / Ethereum networks, members and nodes, plus AMB Access tokens' metadata (accessors). */
const client = (p: string, r: string) => new ManagedBlockchainClient(clientConfig(p, r));

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [networks, accessors] = await Promise.all([
    pageAll((NextToken) => c.send(new ListNetworksCommand({ NextToken })), (r) => r.Networks, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListAccessorsCommand({ NextToken })), (r) => r.Accessors, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...networks.map((n) => ({ id: `net:${n.Id}`, name: n.Name || n.Id || '', group: 'Networks', status: n.Status, info: `${n.Framework} ${n.FrameworkVersion ?? ''}`.trim() })).sort(byName),
    ...accessors.map((a) => ({ id: `acc:${a.Id}`, name: a.Id || '', group: 'Accessors (AMB Access)', status: a.Status, info: [a.Type, a.NetworkType].filter(Boolean).join(' · ') })),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];
  if (kind === 'net') {
    const n = (await c.send(new GetNetworkCommand({ NetworkId: rest }))).Network;
    if (!n) throw httpError(`Network not found: ${rest}`, 404);
    const parts = await settle({ members: pageAll((NextToken) => c.send(new ListMembersCommand({ NetworkId: rest, NextToken })), (r) => r.Members, (r) => r.NextToken) }, errors);
    const owned = (parts.members || []).filter((m) => m.IsOwned);
    const nodes = (await mapLimited(owned, 3, (m) => pageAll((NextToken) => c.send(new ListNodesCommand({ NetworkId: rest, MemberId: m.Id, NextToken })), (r) => r.Nodes, (r) => r.NextToken).then((ns) => ns.map((x) => ({ ...x, member: m.Name }))).catch(() => []))).flat();
    // Ethereum public networks have no members - their nodes are listed without a member.
    const ethNodes = n.Framework === 'ETHEREUM' ? await pageAll((NextToken) => c.send(new ListNodesCommand({ NetworkId: rest, NextToken })), (r) => r.Nodes, (r) => r.NextToken).catch(() => []) : [];
    const fab = n.FrameworkAttributes?.Fabric;
    return {
      id,
      title: n.Name || rest,
      subtitle: `${n.Framework} ${n.FrameworkVersion ?? ''} network`,
      status: n.Status,
      arn: n.Arn,
      tabs: [
        tab('Details', {
          sections: [section('Network', [['Network ID', n.Id], ['Framework', `${n.Framework} ${n.FrameworkVersion ?? ''}`], ['Edition', fab?.Edition], ['Ordering endpoint', fab?.OrderingServiceEndpoint], ['Ethereum chain', n.FrameworkAttributes?.Ethereum?.ChainId], ['Voting', n.VotingPolicy?.ApprovalThresholdPolicy && `${n.VotingPolicy.ApprovalThresholdPolicy.ThresholdPercentage}% ${n.VotingPolicy.ApprovalThresholdPolicy.ThresholdComparator}`], ['VPC endpoint service', n.VpcEndpointServiceName], ['Description', n.Description], ['Created', n.CreationDate]])],
          tables: [table(['Member', 'Status', 'Mine', 'Created'], (parts.members || []).map((m) => [m.Name, m.Status, m.IsOwned, m.CreationDate]), { title: 'Members', statusColumn: 1, emptyMessage: n.Framework === 'ETHEREUM' ? 'Ethereum networks have no members' : 'No members' })],
        }),
        tab('Nodes', {
          tables: [table(['Node', 'Member', 'Instance', 'AZ', 'Status', 'Created'], [...nodes.map((x) => [x.Id, x.member, x.InstanceType, x.AvailabilityZone, x.Status, x.CreationDate]), ...ethNodes.map((x) => [x.Id, '-', x.InstanceType, x.AvailabilityZone, x.Status, x.CreationDate])], { statusColumn: 4, emptyMessage: 'No nodes of yours' })],
        }),
      ],
      tags: tagMap(n.Tags),
      actions: [],
      errors,
    };
  }
  if (kind === 'acc') {
    // The accessor's billing token is never read (GetAccessor returns it) - list metadata only.
    const a = (await pageAll((NextToken) => c.send(new ListAccessorsCommand({ NextToken })), (r) => r.Accessors, (r) => r.NextToken)).find((x) => x.Id === rest);
    if (!a) throw httpError(`Accessor not found: ${rest}`, 404);
    return { id, title: rest, subtitle: 'AMB Access accessor', status: a.Status, arn: a.Arn, tabs: [tab('Details', { sections: [section('Accessor', [['Type', a.Type], ['Network', a.NetworkType], ['Status', a.Status], ['Created', a.CreationDate]], { note: 'The billing token is not shown.' })] })], actions: [], errors };
  }
  throw httpError(`Unknown Managed Blockchain page: ${id}`, 400);
}

export const managedBlockchainAdapter: PageServiceAdapter = {
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
  countable: (row) => row.id.startsWith('net:'),
};
