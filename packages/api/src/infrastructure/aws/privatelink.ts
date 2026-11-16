import {
  DescribeVpcEndpointsCommand,
  DescribeVpcEndpointServiceConfigurationsCommand,
  DescribeVpcEndpointServicePermissionsCommand,
  DescribeVpcEndpointConnectionsCommand,
} from '@aws-sdk/client-ec2';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';
import { ec2, describeAll, nameTag, ec2TagFns } from './ec2-pages.js';

/** PrivateLink = VPC endpoints this account uses + endpoint services it offers. */
async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = ec2(profile, region);
  const [eps, svcs] = await Promise.all([
    describeAll((NextToken) => c.send(new DescribeVpcEndpointsCommand({ NextToken })), (r) => r.VpcEndpoints),
    describeAll((NextToken) => c.send(new DescribeVpcEndpointServiceConfigurationsCommand({ NextToken })), (r) => r.ServiceConfigurations),
  ]);
  return [
    ...eps
      .map((e) => ({ id: `ep:${e.VpcEndpointId}`, name: nameTag(e.Tags) ?? e.VpcEndpointId ?? '', group: 'Endpoints', status: e.State, info: [e.VpcEndpointType, e.ServiceName?.replace(`com.amazonaws.${region}.`, ''), e.VpcId].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    ...svcs
      .map((s) => ({ id: `svc:${s.ServiceId}`, name: nameTag(s.Tags) ?? s.ServiceId ?? '', group: 'Endpoint services', status: s.ServiceState, info: [s.ServiceType?.[0]?.ServiceType, s.AcceptanceRequired ? 'acceptance required' : 'auto-accept'].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

const pretty = (raw?: string) => {
  if (!raw) return undefined;
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
};

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const [kind, rid] = splitId(id);
  const errors: string[] = [];

  if (kind === 'ep') {
    const e = (await c.send(new DescribeVpcEndpointsCommand({ VpcEndpointIds: [rid] }))).VpcEndpoints?.[0];
    if (!e) throw httpError(`Endpoint not found: ${rid}`, 404);
    return {
      id,
      title: nameTag(e.Tags) ?? rid,
      subtitle: `${e.VpcEndpointType} · ${e.ServiceName}`,
      status: e.State,
      arn: e.OwnerId ? `arn:aws:ec2:${region}:${e.OwnerId}:vpc-endpoint/${rid}` : undefined,
      tabs: [
        tab('Details', {
          sections: [
            section('Details', [
              ['Endpoint ID', rid],
              ['Type', e.VpcEndpointType],
              ['Service name', e.ServiceName],
              ['VPC', e.VpcId],
              ['Private DNS names', e.PrivateDnsEnabled],
              ['DNS record IP type', e.DnsOptions?.DnsRecordIpType],
              ['IP address type', e.IpAddressType],
              ['Requester managed', e.RequesterManaged],
              ['Created', e.CreationTimestamp],
              ['Owner', e.OwnerId],
            ]),
            { title: 'DNS names', settings: [], copyable: (e.DnsEntries || []).map((d) => ({ label: d.HostedZoneId ? `Zone ${d.HostedZoneId}` : 'DNS name', value: d.DnsName || '-' })) },
          ].filter((s) => s.settings.length || s.copyable?.length),
        }),
        tab('Network', {
          sections: [
            section('Placement', [
              ['Subnets', e.SubnetIds],
              ['Network interfaces', e.NetworkInterfaceIds],
              ['Security groups', (e.Groups || []).map((g) => `${g.GroupId} (${g.GroupName})`)],
              ['Route tables', e.RouteTableIds],
            ]),
          ],
        }),
        tab('Policy', { json: pretty(e.PolicyDocument), emptyMessage: 'Interface endpoints without a policy allow full access.' }),
      ],
      tags: tagList(e.Tags),
      actions: [],
      errors,
    };
  }

  if (kind === 'svc') {
    const s = (await c.send(new DescribeVpcEndpointServiceConfigurationsCommand({ ServiceIds: [rid] }))).ServiceConfigurations?.[0];
    if (!s) throw httpError(`Endpoint service not found: ${rid}`, 404);
    const { perms, conns } = await settle(
      {
        perms: c.send(new DescribeVpcEndpointServicePermissionsCommand({ ServiceId: rid })),
        conns: describeAll((NextToken) => c.send(new DescribeVpcEndpointConnectionsCommand({ Filters: [{ Name: 'service-id', Values: [rid] }], NextToken })), (r) => r.VpcEndpointConnections),
      },
      errors,
    );
    return {
      id,
      title: nameTag(s.Tags) ?? rid,
      subtitle: s.ServiceName,
      status: s.ServiceState,
      tabs: [
        tab('Details', {
          sections: [
            section('Details', [
              ['Service ID', rid],
              ['Service name', s.ServiceName],
              ['Type', s.ServiceType?.map((t) => t.ServiceType)],
              ['Acceptance required', s.AcceptanceRequired],
              ['Availability Zones', s.AvailabilityZones],
              ['Network Load Balancers', (s.NetworkLoadBalancerArns || []).map((a) => a.split('/').slice(-2).join('/'))],
              ['Gateway Load Balancers', (s.GatewayLoadBalancerArns || []).map((a) => a.split('/').slice(-2).join('/'))],
              ['Supported IP address types', s.SupportedIpAddressTypes],
              ['Private DNS name', s.PrivateDnsName],
              ['Private DNS verification', s.PrivateDnsNameConfiguration?.State],
            ]),
            { title: 'Base DNS names', settings: [], copyable: (s.BaseEndpointDnsNames || []).map((d) => ({ label: 'DNS name', value: d })) },
          ].filter((x) => x.settings.length || x.copyable?.length),
        }),
        tab('Endpoint connections', {
          tables: [
            table(['Endpoint', 'Owner', 'Created', 'State'], (conns || []).map((cn) => [cn.VpcEndpointId, cn.VpcEndpointOwner, cn.CreationTimestamp, cn.VpcEndpointState]), { statusColumn: 3, emptyMessage: 'No endpoints are connected to this service' }),
          ],
        }),
        tab('Allow principals', {
          tables: [
            table(['Principal', 'Type'], (perms?.AllowedPrincipals || []).map((p) => [p.Principal, p.PrincipalType]), { emptyMessage: 'No principals are allowed - only this account can connect.' }),
          ],
        }),
      ],
      tags: tagList(s.Tags),
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown PrivateLink id: ${id}`, 400);
}

export const privateLinkAdapter: PageServiceAdapter = { list, detail, ...ec2TagFns };
