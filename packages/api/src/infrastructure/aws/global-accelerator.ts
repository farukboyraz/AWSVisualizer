import {
  GlobalAcceleratorClient,
  ListAcceleratorsCommand,
  ListCustomRoutingAcceleratorsCommand,
  DescribeAcceleratorCommand,
  DescribeCustomRoutingAcceleratorCommand,
  DescribeAcceleratorAttributesCommand,
  ListListenersCommand,
  ListEndpointGroupsCommand,
  ListCustomRoutingListenersCommand,
  ListCustomRoutingEndpointGroupsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  UpdateAcceleratorCommand,
  type Accelerator,
  type CustomRoutingAccelerator,
  type PortRange,
} from '@aws-sdk/client-global-accelerator';
import { cachedCredentials } from './credential-cache.js';
import type { PageAction, ResourcePage, PageSummary, PageTable } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Global Accelerator is a global service whose API lives only in us-west-2. */
const API_REGION = 'us-west-2';
const client = (p: string) => new GlobalAcceleratorClient({ region: API_REGION, credentials: cachedCredentials(p) });

interface ListenerInfo {
  ListenerArn?: string;
  PortRanges?: PortRange[];
  Protocol?: string;
  ClientAffinity?: string;
}

const ports = (r?: PortRange[]) => (r || []).map((p) => (p.FromPort === p.ToPort ? `${p.FromPort}` : `${p.FromPort}-${p.ToPort}`)).join(', ');

async function list(profile: string): Promise<PageSummary[]> {
  const c = client(profile);
  const std: Accelerator[] = [];
  const custom: CustomRoutingAccelerator[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new ListAcceleratorsCommand({ NextToken }));
    std.push(...(res.Accelerators || []));
    NextToken = res.NextToken;
  } while (NextToken);
  try {
    do {
      const res = await c.send(new ListCustomRoutingAcceleratorsCommand({ NextToken }));
      custom.push(...(res.Accelerators || []));
      NextToken = res.NextToken;
    } while (NextToken);
  } catch {
    // Custom routing needs its own permission; standard accelerators still list.
  }
  const row = (a: Accelerator | CustomRoutingAccelerator, kind: 'std' | 'custom') => ({
    id: `${kind}:${a.AcceleratorArn}`,
    name: a.Name ?? '',
    group: kind === 'std' ? 'Standard accelerators' : 'Custom routing accelerators',
    status: a.Enabled === false ? 'DISABLED' : a.Status,
    info: [a.DnsName, (a.IpSets || []).flatMap((s) => s.IpAddresses || []).join(', ')].filter(Boolean).join(' · '),
  });
  return [...std.map((a) => row(a, 'std')), ...custom.map((a) => row(a, 'custom'))];
}

function actions(a: Accelerator): PageAction[] {
  if (a.Status !== 'DEPLOYED') return [];
  return a.Enabled
    ? [{ id: 'disable', title: 'Disable', systemImage: 'pause.fill', confirmTitle: `Disable ${a.Name}?`, confirmMessage: 'The static IPs stop accepting traffic (they stay allocated to the accelerator).', destructive: true }]
    : [{ id: 'enable', title: 'Enable', systemImage: 'play.fill', confirmTitle: `Enable ${a.Name}?`, confirmMessage: 'The static IPs start accepting traffic again.', destructive: false }];
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const c = client(profile);
  const [kind, arn] = splitId(id);
  if ((kind !== 'std' && kind !== 'custom') || !arn) throw httpError(`Unknown accelerator id: ${id}`, 400);
  const errors: string[] = [];
  const isCustom = kind === 'custom';
  const a = isCustom
    ? (await c.send(new DescribeCustomRoutingAcceleratorCommand({ AcceleratorArn: arn }))).Accelerator
    : (await c.send(new DescribeAcceleratorCommand({ AcceleratorArn: arn }))).Accelerator;
  if (!a) throw httpError('Accelerator not found', 404);

  const { attrs, tags, listeners } = await settle(
    {
      attrs: isCustom ? Promise.resolve(undefined) : c.send(new DescribeAcceleratorAttributesCommand({ AcceleratorArn: arn })),
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
      listeners: (isCustom
        ? c.send(new ListCustomRoutingListenersCommand({ AcceleratorArn: arn })).then((r) => (r.Listeners || []).map((l) => ({ ListenerArn: l.ListenerArn, PortRanges: l.PortRanges, Protocol: 'custom routing' })))
        : c.send(new ListListenersCommand({ AcceleratorArn: arn })).then((r) => r.Listeners || [])) as Promise<ListenerInfo[]>,
    },
    errors,
  );

  const groupTables: PageTable[] = [];
  for (const l of listeners || []) {
    try {
      if (isCustom) {
        const groups = (await c.send(new ListCustomRoutingEndpointGroupsCommand({ ListenerArn: l.ListenerArn }))).EndpointGroups || [];
        for (const g of groups) {
          groupTables.push(table(['Subnet endpoint', 'Traffic'], (g.EndpointDescriptions || []).map((e) => [e.EndpointId, 'allowed per destination']), { title: `Listener ${ports(l.PortRanges)} · ${g.EndpointGroupRegion} · destinations ${(g.DestinationDescriptions || []).map((d) => `${d.Protocols?.join('/')} ${d.FromPort}-${d.ToPort}`).join(', ')}`, emptyMessage: 'No subnets' }));
        }
      } else {
        const groups = (await c.send(new ListEndpointGroupsCommand({ ListenerArn: l.ListenerArn }))).EndpointGroups || [];
        for (const g of groups) {
          groupTables.push(
            table(
              ['Endpoint', 'Weight', 'Client IP preservation', 'Health', 'Reason'],
              (g.EndpointDescriptions || []).map((e) => [e.EndpointId?.split(/[:/]/).slice(-2).join('/'), e.Weight, e.ClientIPPreservationEnabled, e.HealthState, e.HealthReason]),
              { title: `Listener ${l.Protocol} ${ports(l.PortRanges)} · ${g.EndpointGroupRegion} · traffic dial ${g.TrafficDialPercentage ?? 100}% · health check ${g.HealthCheckProtocol} ${g.HealthCheckPort ?? ''}${g.HealthCheckPath ?? ''}`, statusColumn: 3, emptyMessage: 'No endpoints' },
            ),
          );
        }
      }
    } catch (err) {
      errors.push(`Endpoint groups of listener ${ports(l.PortRanges)}: ${err instanceof Error ? err.message : err}`);
    }
  }

  return {
    id,
    title: a.Name ?? '',
    subtitle: isCustom ? 'Custom routing accelerator' : 'Standard accelerator',
    status: a.Enabled === false ? 'DISABLED' : a.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Details', [
            ['Status', a.Status],
            ['Enabled', a.Enabled],
            ['IP address type', a.IpAddressType],
            ['Created', a.CreatedTime],
            ['Last modified', a.LastModifiedTime],
            ['Flow logs', attrs?.AcceleratorAttributes?.FlowLogsEnabled ? `s3://${attrs.AcceleratorAttributes.FlowLogsS3Bucket}/${attrs.AcceleratorAttributes.FlowLogsS3Prefix ?? ''}` : attrs ? 'Disabled' : undefined],
          ]),
          {
            title: 'Static IP addresses and DNS',
            settings: [],
            copyable: [
              ...(a.DnsName ? [{ label: 'DNS name', value: a.DnsName }] : []),
              ...((a as Accelerator).DualStackDnsName ? [{ label: 'Dual-stack DNS name', value: (a as Accelerator).DualStackDnsName as string }] : []),
              ...(a.IpSets || []).map((s) => ({ label: `${s.IpAddressFamily ?? s.IpFamily} addresses`, value: (s.IpAddresses || []).join(', ') })),
            ],
          },
        ],
      }),
      tab('Listeners', {
        tables: [table(['Ports', 'Protocol', 'Client affinity'], (listeners || []).map((l) => [ports(l.PortRanges), l.Protocol, l.ClientAffinity]), { emptyMessage: 'No listeners' })],
      }),
      tab('Endpoint groups', { tables: groupTables, emptyMessage: 'No endpoint groups' }),
    ],
    tags: tags ? tagList(tags.Tags) : undefined,
    actions: isCustom ? [] : actions(a as Accelerator),
    errors,
  };
}

export const globalAcceleratorAdapter: PageServiceAdapter = {
  list: (profile) => list(profile),
  detail,
  async action(profile, _region, id, action) {
    const [kind, arn] = splitId(id);
    if (kind !== 'std') throw httpError('Enable/disable is only offered for standard accelerators', 400);
    if (action !== 'enable' && action !== 'disable') throw httpError('action must be enable or disable', 400);
    await client(profile).send(new UpdateAcceleratorCommand({ AcceleratorArn: arn, Enabled: action === 'enable' }));
  },
  async addTag(profile, _region, _id, arn, key, value) {
    await client(profile).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, _region, _id, arn, key) {
    await client(profile).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
};
