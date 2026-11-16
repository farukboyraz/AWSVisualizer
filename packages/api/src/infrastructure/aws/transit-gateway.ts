import {
  DescribeTransitGatewaysCommand,
  DescribeTransitGatewayAttachmentsCommand,
  DescribeTransitGatewayRouteTablesCommand,
  SearchTransitGatewayRoutesCommand,
} from '@aws-sdk/client-ec2';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';
import { ec2, describeAll, nameTag, ec2TagFns } from './ec2-pages.js';

/** Routes shown per route table (SearchTransitGatewayRoutes max page). */
const ROUTE_LIMIT = 1000;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = ec2(profile, region);
  const [tgws, atts] = await Promise.all([
    describeAll((NextToken) => c.send(new DescribeTransitGatewaysCommand({ NextToken })), (r) => r.TransitGateways),
    describeAll((NextToken) => c.send(new DescribeTransitGatewayAttachmentsCommand({ NextToken })), (r) => r.TransitGatewayAttachments).catch(() => []),
  ]);
  return tgws
    .map((t) => ({
      id: `tgw:${t.TransitGatewayId}`,
      name: nameTag(t.Tags) ?? t.TransitGatewayId ?? '',
      status: t.State,
      info: [t.TransitGatewayId, `ASN ${t.Options?.AmazonSideAsn ?? '-'}`, `${atts.filter((a) => a.TransitGatewayId === t.TransitGatewayId).length} attachments`].join(' · '),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const tgwId = id.replace(/^tgw:/, '');
  const t = (await c.send(new DescribeTransitGatewaysCommand({ TransitGatewayIds: [tgwId] }))).TransitGateways?.[0];
  if (!t) throw httpError(`Transit gateway not found: ${tgwId}`, 404);
  const errors: string[] = [];
  const f = [{ Name: 'transit-gateway-id', Values: [tgwId] }];
  const { atts, rts } = await settle(
    {
      atts: describeAll((NextToken) => c.send(new DescribeTransitGatewayAttachmentsCommand({ Filters: f, NextToken })), (r) => r.TransitGatewayAttachments),
      rts: describeAll((NextToken) => c.send(new DescribeTransitGatewayRouteTablesCommand({ Filters: f, NextToken })), (r) => r.TransitGatewayRouteTables),
    },
    errors,
  );
  const routes = await Promise.all(
    (rts || []).map((rt) =>
      c
        .send(new SearchTransitGatewayRoutesCommand({ TransitGatewayRouteTableId: rt.TransitGatewayRouteTableId, Filters: [{ Name: 'state', Values: ['active', 'blackhole'] }], MaxResults: ROUTE_LIMIT }))
        .catch((err) => {
          errors.push(`Routes of ${rt.TransitGatewayRouteTableId}: ${err instanceof Error ? err.message : err}`);
          return undefined;
        }),
    ),
  );
  const o = t.Options;
  return {
    id,
    title: nameTag(t.Tags) ?? tgwId,
    subtitle: t.Description || tgwId,
    status: t.State,
    arn: t.TransitGatewayArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Details', [
            ['Transit gateway ID', tgwId],
            ['State', t.State],
            ['Amazon side ASN', o?.AmazonSideAsn],
            ['CIDR blocks', o?.TransitGatewayCidrBlocks],
            ['DNS support', o?.DnsSupport],
            ['VPN ECMP support', o?.VpnEcmpSupport],
            ['Multicast support', o?.MulticastSupport],
            ['Security group referencing', o?.SecurityGroupReferencingSupport],
            ['Auto accept shared attachments', o?.AutoAcceptSharedAttachments],
            ['Default route table association', o?.DefaultRouteTableAssociation],
            ['Association route table', o?.AssociationDefaultRouteTableId],
            ['Default route table propagation', o?.DefaultRouteTablePropagation],
            ['Propagation route table', o?.PropagationDefaultRouteTableId],
            ['Owner', t.OwnerId],
            ['Created', t.CreationTime],
          ]),
        ],
      }),
      tab('Attachments', {
        tables: [
          table(
            ['Attachment', 'Name', 'Type', 'Resource', 'Resource owner', 'Route table', 'State'],
            (atts || []).map((a) => [a.TransitGatewayAttachmentId, nameTag(a.Tags) ?? '-', a.ResourceType, a.ResourceId, a.ResourceOwnerId, a.Association?.TransitGatewayRouteTableId, a.State]),
            { statusColumn: 6, emptyMessage: 'No attachments' },
          ),
        ],
      }),
      tab('Route tables', {
        tables: (rts || []).map((rt, i) =>
          table(
            ['Destination', 'Attachments', 'Type', 'State'],
            (routes[i]?.Routes || []).map((r) => [r.DestinationCidrBlock ?? r.PrefixListId, (r.TransitGatewayAttachments || []).map((a) => `${a.ResourceId} (${a.ResourceType})`), r.Type, r.State]),
            {
              title: `${nameTag(rt.Tags) ?? rt.TransitGatewayRouteTableId}${rt.DefaultAssociationRouteTable ? ' · default association' : ''}${rt.DefaultPropagationRouteTable ? ' · default propagation' : ''}${routes[i]?.AdditionalRoutesAvailable ? ` · first ${ROUTE_LIMIT} routes` : ''}`,
              statusColumn: 3,
              emptyMessage: 'No routes',
            },
          ),
        ),
      }),
    ],
    tags: tagList(t.Tags),
    actions: [],
    errors,
  };
}

export const transitGatewayAdapter: PageServiceAdapter = singleKind('tgw', { list, detail, ...ec2TagFns });
