import {
  DescribeVpcsCommand,
  DescribeVpcAttributeCommand,
  DescribeSubnetsCommand,
  DescribeRouteTablesCommand,
  DescribeInternetGatewaysCommand,
  DescribeNatGatewaysCommand,
  DescribeSecurityGroupsCommand,
  DescribeNetworkAclsCommand,
  DescribeVpcPeeringConnectionsCommand,
  DescribeFlowLogsCommand,
  DescribeVpcEndpointsCommand,
  type IpPermission,
  type Route,
  type SecurityGroup,
  type Vpc,
} from '@aws-sdk/client-ec2';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';
import { ec2, describeAll, nameTag, ec2TagFns, portText } from './ec2-pages.js';

const vpcFilter = (vpcId: string) => [{ Name: 'vpc-id', Values: [vpcId] }];

function routeTarget(r: Route): string {
  return r.GatewayId || r.NatGatewayId || r.TransitGatewayId || r.VpcPeeringConnectionId || r.NetworkInterfaceId || r.InstanceId || r.EgressOnlyInternetGatewayId || r.LocalGatewayId || r.CarrierGatewayId || r.CoreNetworkArn || '-';
}

/** One row per source of a rule - the console's flattened rule list. */
function ruleRows(perms: IpPermission[] | undefined): unknown[][] {
  const rows: unknown[][] = [];
  for (const p of perms || []) {
    const port = portText(p.IpProtocol, p.FromPort, p.ToPort);
    const sources: [string, string | undefined][] = [
      ...(p.IpRanges || []).map((r) => [r.CidrIp || '', r.Description] as [string, string | undefined]),
      ...(p.Ipv6Ranges || []).map((r) => [r.CidrIpv6 || '', r.Description] as [string, string | undefined]),
      ...(p.PrefixListIds || []).map((r) => [r.PrefixListId || '', r.Description] as [string, string | undefined]),
      ...(p.UserIdGroupPairs || []).map((g) => [`${g.GroupId}${g.UserId ? ` (${g.UserId})` : ''}`, g.Description] as [string, string | undefined]),
    ];
    for (const [src, desc] of sources.length ? sources : [['-', undefined] as [string, undefined]]) rows.push([port, src, desc]);
  }
  return rows;
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = ec2(profile, region);
  const [vpcs, sgs] = await Promise.all([
    describeAll((NextToken) => c.send(new DescribeVpcsCommand({ NextToken })), (r) => r.Vpcs),
    describeAll((NextToken) => c.send(new DescribeSecurityGroupsCommand({ NextToken })), (r) => r.SecurityGroups),
  ]);
  const vpcName = new Map(vpcs.map((v) => [v.VpcId, nameTag(v.Tags) ?? v.VpcId]));
  return [
    ...vpcs
      .map((v) => ({ id: `vpc:${v.VpcId}`, name: nameTag(v.Tags) ?? v.VpcId ?? '', group: 'VPCs', status: v.State, info: [v.VpcId, v.CidrBlock, v.IsDefault ? 'default' : undefined].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    ...sgs
      .map((g) => ({ id: `sg:${g.GroupId}`, name: g.GroupName ?? g.GroupId ?? '', group: 'Security groups', info: [g.GroupId, vpcName.get(g.VpcId), `${g.IpPermissions?.length ?? 0} in / ${g.IpPermissionsEgress?.length ?? 0} out`].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

function vpcArn(region: string, v: Vpc) {
  return v.OwnerId ? `arn:aws:ec2:${region}:${v.OwnerId}:vpc/${v.VpcId}` : undefined;
}

async function vpcPage(profile: string, region: string, vpcId: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const v = (await c.send(new DescribeVpcsCommand({ VpcIds: [vpcId] }))).Vpcs?.[0];
  if (!v) throw httpError(`VPC not found: ${vpcId}`, 404);
  const errors: string[] = [];
  const f = vpcFilter(vpcId);
  const p = await settle(
    {
      dnsSupport: c.send(new DescribeVpcAttributeCommand({ VpcId: vpcId, Attribute: 'enableDnsSupport' })),
      dnsHostnames: c.send(new DescribeVpcAttributeCommand({ VpcId: vpcId, Attribute: 'enableDnsHostnames' })),
      subnets: describeAll((NextToken) => c.send(new DescribeSubnetsCommand({ Filters: f, NextToken })), (r) => r.Subnets),
      routeTables: describeAll((NextToken) => c.send(new DescribeRouteTablesCommand({ Filters: f, NextToken })), (r) => r.RouteTables),
      igws: describeAll((NextToken) => c.send(new DescribeInternetGatewaysCommand({ Filters: [{ Name: 'attachment.vpc-id', Values: [vpcId] }], NextToken })), (r) => r.InternetGateways),
      nats: describeAll((NextToken) => c.send(new DescribeNatGatewaysCommand({ Filter: f, NextToken })), (r) => r.NatGateways),
      sgs: describeAll((NextToken) => c.send(new DescribeSecurityGroupsCommand({ Filters: f, NextToken })), (r) => r.SecurityGroups),
      nacls: describeAll((NextToken) => c.send(new DescribeNetworkAclsCommand({ Filters: f, NextToken })), (r) => r.NetworkAcls),
      peerings: describeAll((NextToken) => c.send(new DescribeVpcPeeringConnectionsCommand({ Filters: [{ Name: 'requester-vpc-info.vpc-id', Values: [vpcId] }], NextToken })), (r) => r.VpcPeeringConnections),
      peeringsIn: describeAll((NextToken) => c.send(new DescribeVpcPeeringConnectionsCommand({ Filters: [{ Name: 'accepter-vpc-info.vpc-id', Values: [vpcId] }], NextToken })), (r) => r.VpcPeeringConnections),
      endpoints: describeAll((NextToken) => c.send(new DescribeVpcEndpointsCommand({ Filters: f, NextToken })), (r) => r.VpcEndpoints),
      flowLogs: describeAll((NextToken) => c.send(new DescribeFlowLogsCommand({ Filter: [{ Name: 'resource-id', Values: [vpcId] }], NextToken })), (r) => r.FlowLogs),
    },
    errors,
  );
  const subnetName = new Map((p.subnets || []).map((s) => [s.SubnetId, nameTag(s.Tags) ?? s.SubnetId]));
  const mainRt = (p.routeTables || []).find((rt) => rt.Associations?.some((a) => a.Main));
  // Subnets without an explicit association use the main route table.
  const rtOfSubnet = new Map<string | undefined, string | undefined>();
  for (const rt of p.routeTables || []) for (const a of rt.Associations || []) if (a.SubnetId) rtOfSubnet.set(a.SubnetId, rt.RouteTableId);
  const publicRts = new Set((p.routeTables || []).filter((rt) => rt.Routes?.some((r) => r.GatewayId?.startsWith('igw-'))).map((rt) => rt.RouteTableId));
  const peerings = [...(p.peerings || []), ...(p.peeringsIn || [])];

  return {
    id: `vpc:${vpcId}`,
    title: nameTag(v.Tags) ?? vpcId,
    subtitle: `${vpcId} · ${v.CidrBlock}`,
    status: v.State,
    arn: vpcArn(region, v),
    tabs: [
      tab('Details', {
        sections: [
          section('Details', [
            ['VPC ID', vpcId],
            ['State', v.State],
            ['IPv4 CIDRs', (v.CidrBlockAssociationSet || []).map((a) => a.CidrBlock)],
            ['IPv6 CIDRs', (v.Ipv6CidrBlockAssociationSet || []).map((a) => a.Ipv6CidrBlock)],
            ['Default VPC', v.IsDefault ? 'Yes' : 'No'],
            ['Tenancy', v.InstanceTenancy],
            ['DHCP option set', v.DhcpOptionsId],
            ['DNS resolution', p.dnsSupport?.EnableDnsSupport?.Value],
            ['DNS hostnames', p.dnsHostnames?.EnableDnsHostnames?.Value],
            ['Main route table', mainRt?.RouteTableId],
            ['Owner', v.OwnerId],
          ]),
          section('Resource counts', [
            ['Subnets', p.subnets?.length],
            ['Route tables', p.routeTables?.length],
            ['Internet gateways', p.igws?.length],
            ['NAT gateways', (p.nats || []).filter((n) => n.State !== 'deleted').length],
            ['Security groups', p.sgs?.length],
            ['Network ACLs', p.nacls?.length],
            ['Peering connections', peerings.length],
            ['VPC endpoints', p.endpoints?.length],
          ]),
        ],
      }),
      tab('Subnets', {
        tables: [
          table(
            ['Name', 'Subnet ID', 'Availability Zone', 'IPv4 CIDR', 'Free IPs', 'Route table', 'Public IP on launch', 'State'],
            (p.subnets || [])
              .sort((a, b) => (a.AvailabilityZone || '').localeCompare(b.AvailabilityZone || ''))
              .map((s) => {
                const rt = rtOfSubnet.get(s.SubnetId) ?? mainRt?.RouteTableId;
                return [nameTag(s.Tags) ?? '-', s.SubnetId, s.AvailabilityZone, s.CidrBlock, s.AvailableIpAddressCount, `${rt ?? '-'}${publicRts.has(rt) ? ' (public)' : ''}`, s.MapPublicIpOnLaunch, s.State];
              }),
            { statusColumn: 7, emptyMessage: 'No subnets' },
          ),
        ],
      }),
      tab('Route tables', {
        tables: (p.routeTables || []).map((rt) =>
          table(
            ['Destination', 'Target', 'Origin', 'State'],
            (rt.Routes || []).map((r) => [r.DestinationCidrBlock ?? r.DestinationIpv6CidrBlock ?? r.DestinationPrefixListId, routeTarget(r), r.Origin, r.State]),
            {
              title: `${nameTag(rt.Tags) ?? rt.RouteTableId}${rt.Associations?.some((a) => a.Main) ? ' (main)' : ''} · ${(rt.Associations || []).filter((a) => a.SubnetId).map((a) => subnetName.get(a.SubnetId)).join(', ') || 'no explicit subnets'}`,
              statusColumn: 3,
            },
          ),
        ),
      }),
      tab('Gateways', {
        tables: [
          table(['Internet gateway', 'Name', 'State'], (p.igws || []).map((g) => [g.InternetGatewayId, nameTag(g.Tags) ?? '-', g.Attachments?.find((a) => a.VpcId === vpcId)?.State]), { title: 'Internet gateways', statusColumn: 2, emptyMessage: 'No internet gateway - the VPC has no direct internet route.' }),
          table(
            ['NAT gateway', 'Name', 'Type', 'Subnet', 'Public IP', 'Private IP', 'State'],
            (p.nats || []).filter((n) => n.State !== 'deleted').map((n) => [n.NatGatewayId, nameTag(n.Tags) ?? '-', n.ConnectivityType, subnetName.get(n.SubnetId) ?? n.SubnetId, n.NatGatewayAddresses?.map((a) => a.PublicIp).filter(Boolean), n.NatGatewayAddresses?.map((a) => a.PrivateIp), n.State]),
            { title: 'NAT gateways', statusColumn: 6, emptyMessage: 'No NAT gateways' },
          ),
          table(
            ['Endpoint', 'Service', 'Type', 'State'],
            (p.endpoints || []).map((e) => [e.VpcEndpointId, e.ServiceName, e.VpcEndpointType, e.State]),
            { title: 'VPC endpoints (details under PrivateLink)', statusColumn: 3, emptyMessage: 'No VPC endpoints' },
          ),
        ],
      }),
      tab('Security', {
        tables: [
          table(
            ['Group name', 'Group ID', 'Description', 'Inbound rules', 'Outbound rules'],
            (p.sgs || []).map((g) => [g.GroupName, g.GroupId, g.Description, g.IpPermissions?.length ?? 0, g.IpPermissionsEgress?.length ?? 0]),
            { title: 'Security groups (rules: select the group in the list)' },
          ),
          ...(p.nacls || []).map((n) =>
            table(
              ['Rule #', 'Direction', 'Protocol / port', 'CIDR', 'Action'],
              (n.Entries || [])
                .sort((a, b) => Number(a.Egress) - Number(b.Egress) || (a.RuleNumber ?? 0) - (b.RuleNumber ?? 0))
                .map((e) => [e.RuleNumber === 32767 ? '*' : e.RuleNumber, e.Egress ? 'Outbound' : 'Inbound', portText(e.Protocol, e.PortRange?.From, e.PortRange?.To), e.CidrBlock ?? e.Ipv6CidrBlock, e.RuleAction]),
              { title: `Network ACL ${nameTag(n.Tags) ?? n.NetworkAclId}${n.IsDefault ? ' (default)' : ''} · ${(n.Associations || []).length} subnets` },
            ),
          ),
        ],
      }),
      tab('Peering & flow logs', {
        tables: [
          table(
            ['Peering connection', 'Requester', 'Accepter', 'Status'],
            peerings.map((pc) => [pc.VpcPeeringConnectionId, `${pc.RequesterVpcInfo?.VpcId} (${pc.RequesterVpcInfo?.CidrBlock}, ${pc.RequesterVpcInfo?.Region})`, `${pc.AccepterVpcInfo?.VpcId} (${pc.AccepterVpcInfo?.CidrBlock}, ${pc.AccepterVpcInfo?.Region})`, pc.Status?.Code]),
            { title: 'Peering connections', statusColumn: 3, emptyMessage: 'No peering connections' },
          ),
          table(
            ['Flow log', 'Traffic', 'Destination', 'Interval', 'Status'],
            (p.flowLogs || []).map((fl) => [fl.FlowLogId, fl.TrafficType, fl.LogDestination ?? fl.LogGroupName, fl.MaxAggregationInterval ? `${fl.MaxAggregationInterval} s` : undefined, fl.FlowLogStatus]),
            { title: 'Flow logs', statusColumn: 4, emptyMessage: 'Flow logs are not enabled for this VPC' },
          ),
        ],
      }),
    ],
    tags: tagList(v.Tags),
    actions: [],
    errors,
  };
}

function sgPage(region: string, g: SecurityGroup): ResourcePage {
  return {
    id: `sg:${g.GroupId}`,
    title: g.GroupName ?? g.GroupId ?? '',
    subtitle: `${g.GroupId} · ${g.VpcId}`,
    arn: g.OwnerId ? `arn:aws:ec2:${region}:${g.OwnerId}:security-group/${g.GroupId}` : undefined,
    tabs: [
      tab('Inbound rules', {
        sections: [section('Details', [['Description', g.Description], ['VPC', g.VpcId], ['Owner', g.OwnerId]])],
        tables: [table(['Type / port', 'Source', 'Description'], ruleRows(g.IpPermissions), { emptyMessage: 'No inbound rules - nothing can connect in.' })],
      }),
      tab('Outbound rules', {
        tables: [table(['Type / port', 'Destination', 'Description'], ruleRows(g.IpPermissionsEgress), { emptyMessage: 'No outbound rules - no traffic can leave.' })],
      }),
    ],
    tags: tagList(g.Tags),
    actions: [],
    errors: [],
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rid] = splitId(id);
  if (kind === 'vpc') return vpcPage(profile, region, rid);
  if (kind === 'sg') {
    const g = (await ec2(profile, region).send(new DescribeSecurityGroupsCommand({ GroupIds: [rid] }))).SecurityGroups?.[0];
    if (!g) throw httpError(`Security group not found: ${rid}`, 404);
    return sgPage(region, g);
  }
  throw httpError(`Unknown VPC id: ${id}`, 400);
}

export const vpcAdapter: PageServiceAdapter = { list, detail, ...ec2TagFns };
