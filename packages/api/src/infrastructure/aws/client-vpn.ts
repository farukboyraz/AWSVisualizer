import {
  DescribeClientVpnEndpointsCommand,
  DescribeClientVpnTargetNetworksCommand,
  DescribeClientVpnAuthorizationRulesCommand,
  DescribeClientVpnRoutesCommand,
  DescribeClientVpnConnectionsCommand,
  ExportClientVpnClientConfigurationCommand,
} from '@aws-sdk/client-ec2';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';
import { ec2, describeAll, nameTag, ec2TagFns } from './ec2-pages.js';

const bytes = (n?: string) => {
  const v = Number(n);
  if (!n || Number.isNaN(v)) return n;
  return v > 1024 ** 3 ? `${(v / 1024 ** 3).toFixed(2)} GB` : v > 1024 ** 2 ? `${(v / 1024 ** 2).toFixed(1)} MB` : `${(v / 1024).toFixed(0)} KB`;
};

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = ec2(profile, region);
  const eps = await describeAll((NextToken) => c.send(new DescribeClientVpnEndpointsCommand({ NextToken })), (r) => r.ClientVpnEndpoints);
  return eps
    .map((e) => ({ id: `cvpn:${e.ClientVpnEndpointId}`, name: nameTag(e.Tags) ?? e.ClientVpnEndpointId ?? '', status: e.Status?.Code, info: [e.ClientVpnEndpointId, e.ClientCidrBlock, e.SplitTunnel ? 'split tunnel' : 'full tunnel'].join(' · ') }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const epId = id.replace(/^cvpn:/, '');
  const e = (await c.send(new DescribeClientVpnEndpointsCommand({ ClientVpnEndpointIds: [epId] }))).ClientVpnEndpoints?.[0];
  if (!e) throw httpError(`Client VPN endpoint not found: ${epId}`, 404);
  const errors: string[] = [];
  const q = { ClientVpnEndpointId: epId };
  const p = await settle(
    {
      networks: describeAll((NextToken) => c.send(new DescribeClientVpnTargetNetworksCommand({ ...q, NextToken })), (r) => r.ClientVpnTargetNetworks),
      rules: describeAll((NextToken) => c.send(new DescribeClientVpnAuthorizationRulesCommand({ ...q, NextToken })), (r) => r.AuthorizationRules),
      routes: describeAll((NextToken) => c.send(new DescribeClientVpnRoutesCommand({ ...q, NextToken })), (r) => r.Routes),
      connections: describeAll((NextToken) => c.send(new DescribeClientVpnConnectionsCommand({ ...q, NextToken, Filters: [{ Name: 'status', Values: ['active'] }] })), (r) => r.Connections, 1000),
      config: c.send(new ExportClientVpnClientConfigurationCommand(q)),
    },
    errors,
  );
  return {
    id,
    title: nameTag(e.Tags) ?? epId,
    subtitle: e.Description || epId,
    status: e.Status?.Code,
    arn: undefined,
    tabs: [
      tab('Details', {
        sections: [
          section('Details', [
            ['Endpoint ID', epId],
            ['State', e.Status?.Code],
            ['Client IPv4 CIDR', e.ClientCidrBlock],
            ['Split tunnel', e.SplitTunnel],
            ['Transport / port', `${e.TransportProtocol ?? '-'} ${e.VpnPort ?? ''}`.trim()],
            ['VPN protocol', e.VpnProtocol],
            ['DNS servers', e.DnsServers],
            ['VPC', e.VpcId],
            ['Security groups', e.SecurityGroupIds],
            ['Session timeout', e.SessionTimeoutHours !== undefined ? `${e.SessionTimeoutHours} h` : undefined],
            ['Server certificate', e.ServerCertificateArn?.split('/').pop()],
            ['Authentication', (e.AuthenticationOptions || []).map((a) => a.Type?.replace('-authentication', '').replace('certificate', 'mutual (certificate)'))],
            ['Connection logging', e.ConnectionLogOptions?.Enabled ? e.ConnectionLogOptions.CloudwatchLogGroup ?? 'Enabled' : 'Disabled'],
            ['Self-service portal', e.SelfServicePortalUrl],
            ['Created', e.CreationTime],
          ]),
          { title: 'DNS name', settings: [], copyable: e.DnsName ? [{ label: 'Endpoint DNS name', value: e.DnsName }] : [] },
        ],
      }),
      tab('Target network associations', {
        tables: [table(['Association', 'Subnet', 'VPC', 'Security groups', 'Status'], (p.networks || []).map((n) => [n.AssociationId, n.TargetNetworkId, n.VpcId, n.SecurityGroups, n.Status?.Code]), { statusColumn: 4, emptyMessage: 'No subnets associated - clients cannot connect yet.' })],
      }),
      tab('Authorization rules', {
        tables: [table(['Destination', 'Access', 'Description', 'Status'], (p.rules || []).map((r) => [r.DestinationCidr, r.AccessAll ? 'All users' : `Group ${r.GroupId}`, r.Description, r.Status?.Code]), { statusColumn: 3, emptyMessage: 'No authorization rules - connected clients reach nothing.' })],
      }),
      tab('Route table', {
        tables: [table(['Destination', 'Target subnet', 'Type', 'Origin', 'Status'], (p.routes || []).map((r) => [r.DestinationCidr, r.TargetSubnet, r.Type, r.Origin, r.Status?.Code]), { statusColumn: 4, emptyMessage: 'No routes' })],
      }),
      tab('Connections', {
        tables: [
          table(
            ['User / certificate', 'Client IP', 'Connected since', 'In', 'Out', 'Status'],
            (p.connections || []).map((cn) => [cn.Username ?? cn.CommonName, cn.ClientIp, cn.ConnectionEstablishedTime, bytes(cn.IngressBytes), bytes(cn.EgressBytes), cn.Status?.Code]),
            { title: 'Active connections', statusColumn: 5, emptyMessage: 'No active connections' },
          ),
        ],
      }),
      tab('Client configuration', { text: p.config?.ClientConfiguration, emptyMessage: 'Client configuration could not be exported.' }),
    ],
    tags: tagList(e.Tags),
    actions: [],
    errors,
  };
}

export const clientVpnAdapter: PageServiceAdapter = singleKind('cvpn', { list, detail, ...ec2TagFns });
