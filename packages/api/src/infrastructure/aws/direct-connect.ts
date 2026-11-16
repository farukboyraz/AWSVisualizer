import {
  DirectConnectClient,
  DescribeConnectionsCommand,
  DescribeVirtualInterfacesCommand,
  DescribeDirectConnectGatewaysCommand,
  DescribeDirectConnectGatewayAssociationsCommand,
  DescribeDirectConnectGatewayAttachmentsCommand,
  DescribeTagsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type VirtualInterface,
} from '@aws-sdk/client-direct-connect';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

// BGP auth keys, customer router configs and MACsec keys are secrets and
// are never copied into a page.

const client = (p: string, r: string) => new DirectConnectClient({ region: r, credentials: cachedCredentials(p) });

const tagsOf = async (c: DirectConnectClient, arn?: string) => {
  if (!arn) return undefined;
  const res = await c.send(new DescribeTagsCommand({ resourceArns: [arn] }));
  return (res.resourceTags?.[0]?.tags || []).map((t) => ({ key: t.key || '', value: t.value || '' }));
};

/** Direct Connect APIs don't return ARNs; they follow a fixed pattern. */
const dxArn = (region: string, account: string | undefined, kind: string, id: string) => (account ? `arn:aws:directconnect:${region}:${account}:${kind}/${id}` : undefined);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [conns, vifs, gws] = await Promise.all([
    c.send(new DescribeConnectionsCommand({})).then((r) => r.connections || []),
    c.send(new DescribeVirtualInterfacesCommand({})).then((r) => r.virtualInterfaces || []),
    c.send(new DescribeDirectConnectGatewaysCommand({})).then((r) => r.directConnectGateways || []).catch(() => []),
  ]);
  return [
    ...conns.map((x) => ({ id: `con:${x.connectionId}`, name: x.connectionName ?? x.connectionId ?? '', group: 'Connections', status: x.connectionState, info: [x.bandwidth, x.location, x.partnerName].filter(Boolean).join(' · ') })),
    ...vifs.map((v) => ({ id: `vif:${v.virtualInterfaceId}`, name: v.virtualInterfaceName ?? v.virtualInterfaceId ?? '', group: 'Virtual interfaces', status: v.virtualInterfaceState, info: [v.virtualInterfaceType, `VLAN ${v.vlan}`, v.connectionId].filter(Boolean).join(' · ') })),
    ...gws.map((g) => ({ id: `gw:${g.directConnectGatewayId}`, name: g.directConnectGatewayName ?? g.directConnectGatewayId ?? '', group: 'Direct Connect gateways (global)', status: g.directConnectGatewayState, info: `ASN ${g.amazonSideAsn ?? '-'}` })),
  ];
}

function vifTable(vifs: VirtualInterface[]) {
  return table(
    ['Virtual interface', 'Name', 'Type', 'VLAN', 'Gateway', 'State'],
    vifs.map((v) => [v.virtualInterfaceId, v.virtualInterfaceName, v.virtualInterfaceType, v.vlan, v.directConnectGatewayId ?? v.virtualGatewayId, v.virtualInterfaceState]),
    { statusColumn: 5, emptyMessage: 'No virtual interfaces' },
  );
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rid] = splitId(id);
  const errors: string[] = [];

  if (kind === 'con') {
    const x = (await c.send(new DescribeConnectionsCommand({ connectionId: rid }))).connections?.[0];
    if (!x) throw httpError(`Connection not found: ${rid}`, 404);
    const arn = dxArn(region, x.ownerAccount, 'dxcon', rid);
    const { vifs, tags } = await settle({ vifs: c.send(new DescribeVirtualInterfacesCommand({ connectionId: rid })), tags: tagsOf(c, arn) }, errors);
    return {
      id,
      title: x.connectionName ?? rid,
      subtitle: `${x.bandwidth} · ${x.location}`,
      status: x.connectionState,
      arn,
      tabs: [
        tab('Connection', {
          sections: [
            section('Details', [
              ['Connection ID', rid],
              ['State', x.connectionState],
              ['Bandwidth', x.bandwidth],
              ['Location', x.location],
              ['Partner', x.partnerName],
              ['Provider', x.providerName],
              ['VLAN', x.vlan],
              ['LAG', x.lagId],
              ['AWS device', x.awsLogicalDeviceId ?? x.awsDevice],
              ['Logical redundancy', x.hasLogicalRedundancy],
              ['Jumbo frames', x.jumboFrameCapable],
              ['MACsec capable', x.macSecCapable],
              ['Port encryption', x.portEncryptionStatus],
              ['LOA issued', x.loaIssueTime],
              ['Owner', x.ownerAccount],
            ]),
          ],
        }),
        tab('Virtual interfaces', { tables: [vifTable(vifs?.virtualInterfaces || [])] }),
      ],
      tags,
      actions: [],
      errors,
    };
  }

  if (kind === 'vif') {
    const v = (await c.send(new DescribeVirtualInterfacesCommand({ virtualInterfaceId: rid }))).virtualInterfaces?.[0];
    if (!v) throw httpError(`Virtual interface not found: ${rid}`, 404);
    const arn = dxArn(region, v.ownerAccount, 'dxvif', rid);
    const { tags } = await settle({ tags: tagsOf(c, arn) }, errors);
    return {
      id,
      title: v.virtualInterfaceName ?? rid,
      subtitle: `${v.virtualInterfaceType} virtual interface · VLAN ${v.vlan}`,
      status: v.virtualInterfaceState,
      arn,
      tabs: [
        tab('Details', {
          sections: [
            section('Details', [
              ['Virtual interface ID', rid],
              ['Type', v.virtualInterfaceType],
              ['State', v.virtualInterfaceState],
              ['Connection', v.connectionId],
              ['Location', v.location],
              ['VLAN', v.vlan],
              ['MTU', v.mtu],
              ['Jumbo frames', v.jumboFrameCapable],
              ['SiteLink', v.siteLinkEnabled],
              ['Direct Connect gateway', v.directConnectGatewayId],
              ['Virtual private gateway', v.virtualGatewayId],
              ['Customer ASN', v.asn],
              ['Amazon side ASN', v.amazonSideAsn],
              ['Address family', v.addressFamily],
              ['Amazon address', v.amazonAddress],
              ['Customer address', v.customerAddress],
              ['Advertised prefixes', (v.routeFilterPrefixes || []).map((p) => p.cidr)],
              ['Owner', v.ownerAccount],
            ], { note: 'BGP authentication keys and the router configuration are not shown here.' }),
          ],
        }),
        tab('BGP peers', {
          tables: [
            table(
              ['Peer', 'ASN', 'Family', 'Amazon address', 'Customer address', 'BGP status', 'State'],
              (v.bgpPeers || []).map((b) => [b.bgpPeerId, b.asn, b.addressFamily, b.amazonAddress, b.customerAddress, b.bgpStatus, b.bgpPeerState]),
              { statusColumn: 5, emptyMessage: 'No BGP peers' },
            ),
          ],
        }),
      ],
      tags,
      actions: [],
      errors,
    };
  }

  if (kind === 'gw') {
    const g = (await c.send(new DescribeDirectConnectGatewaysCommand({ directConnectGatewayId: rid }))).directConnectGateways?.[0];
    if (!g) throw httpError(`Direct Connect gateway not found: ${rid}`, 404);
    const arn = g.ownerAccount ? `arn:aws:directconnect::${g.ownerAccount}:dx-gateway/${rid}` : undefined;
    const { assocs, atts, tags } = await settle(
      {
        assocs: c.send(new DescribeDirectConnectGatewayAssociationsCommand({ directConnectGatewayId: rid })),
        atts: c.send(new DescribeDirectConnectGatewayAttachmentsCommand({ directConnectGatewayId: rid })),
        tags: tagsOf(c, arn),
      },
      errors,
    );
    return {
      id,
      title: g.directConnectGatewayName ?? rid,
      subtitle: 'Direct Connect gateway (global)',
      status: g.directConnectGatewayState,
      arn,
      tabs: [
        tab('Details', {
          sections: [section('Details', [['Gateway ID', rid], ['Amazon side ASN', g.amazonSideAsn], ['State', g.directConnectGatewayState], ['State change error', g.stateChangeError], ['Owner', g.ownerAccount]])],
        }),
        tab('Gateway associations', {
          tables: [
            table(
              ['Associated gateway', 'Type', 'Region', 'Allowed prefixes', 'State'],
              (assocs?.directConnectGatewayAssociations || []).map((a) => [a.associatedGateway?.id ?? a.virtualGatewayId, a.associatedGateway?.type, a.associatedGateway?.region ?? a.virtualGatewayRegion, (a.allowedPrefixesToDirectConnectGateway || []).map((p) => p.cidr), a.associationState]),
              { statusColumn: 4, emptyMessage: 'No transit or virtual private gateways associated' },
            ),
          ],
        }),
        tab('Virtual interface attachments', {
          tables: [
            table(
              ['Virtual interface', 'Region', 'Owner', 'Type', 'State'],
              (atts?.directConnectGatewayAttachments || []).map((a) => [a.virtualInterfaceId, a.virtualInterfaceRegion, a.virtualInterfaceOwnerAccount, a.attachmentType, a.attachmentState]),
              { statusColumn: 4, emptyMessage: 'No virtual interfaces attached' },
            ),
          ],
        }),
      ],
      tags,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown Direct Connect id: ${id}`, 400);
}

export const directConnectAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ key, value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
};
