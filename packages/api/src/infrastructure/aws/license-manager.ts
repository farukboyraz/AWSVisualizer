import {
  LicenseManagerClient,
  ListLicenseConfigurationsCommand,
  GetLicenseConfigurationCommand,
  ListUsageForLicenseConfigurationCommand,
  ListAssociationsForLicenseConfigurationCommand,
  ListReceivedLicensesCommand,
  ListReceivedGrantsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type GrantedLicense,
  type Grant,
} from '@aws-sdk/client-license-manager';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new LicenseManagerClient({ region: r, credentials: cachedCredentials(p) });

const configs = (c: LicenseManagerClient, arns?: string[]) =>
  pageAll((NextToken) => c.send(new ListLicenseConfigurationsCommand({ NextToken, LicenseConfigurationArns: arns })), (r) => r.LicenseConfigurations, (r) => r.NextToken);
const received = (c: LicenseManagerClient, arns?: string[]) =>
  pageAll((NextToken) => c.send(new ListReceivedLicensesCommand({ NextToken, LicenseArns: arns })), (r) => r.Licenses, (r) => r.NextToken);
const grants = (c: LicenseManagerClient, arns?: string[]) =>
  pageAll((NextToken) => c.send(new ListReceivedGrantsCommand({ NextToken, GrantArns: arns })), (r) => r.Grants, (r) => r.NextToken);

const usage = (consumed?: number, count?: number) => `${consumed ?? 0} of ${count ?? 'unlimited'} used`;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [cfgs, lics, grs] = await Promise.all([configs(c), received(c).catch((): GrantedLicense[] => []), grants(c).catch((): Grant[] => [])]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...cfgs.map((x) => ({ id: `cfg:${x.LicenseConfigurationArn}`, name: x.Name || '', group: 'Self-managed licenses', status: x.Status, info: `${x.LicenseCountingType ?? ''} · ${usage(x.ConsumedLicenses, x.LicenseCount)}` })).sort(byName),
    ...lics.map((l) => ({ id: `lic:${l.LicenseArn}`, name: l.LicenseName || l.ProductName || '', group: 'Granted licenses', status: l.Status, info: [l.ProductName, l.Issuer?.Name && `issued by ${l.Issuer.Name}`].filter(Boolean).join(' · ') })).sort(byName),
    ...grs.map((g) => ({ id: `grant:${g.GrantArn}`, name: g.GrantName || '', group: 'Received grants', status: g.GrantStatus, info: (g.GrantedOperations || []).join(', ') })).sort(byName),
  ];
}

async function configPage(c: LicenseManagerClient, id: string, arn: string): Promise<ResourcePage> {
  const x = await c.send(new GetLicenseConfigurationCommand({ LicenseConfigurationArn: arn }));
  const errors: string[] = [];
  const parts = await settle(
    {
      usage: pageAll((NextToken) => c.send(new ListUsageForLicenseConfigurationCommand({ LicenseConfigurationArn: arn, NextToken })), (r) => r.LicenseConfigurationUsageList, (r) => r.NextToken),
      assocs: pageAll((NextToken) => c.send(new ListAssociationsForLicenseConfigurationCommand({ LicenseConfigurationArn: arn, NextToken })), (r) => r.LicenseConfigurationAssociations, (r) => r.NextToken),
    },
    errors,
  );
  return {
    id,
    title: x.Name || arn,
    subtitle: x.Description || 'Self-managed license',
    status: x.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('License configuration', [
            ['Name', x.Name],
            ['Counting type', x.LicenseCountingType],
            ['License count', x.LicenseCount],
            ['Hard limit', x.LicenseCountHardLimit],
            ['Consumed', x.ConsumedLicenses],
            ['Rules', x.LicenseRules],
            ['Disassociate when not found', x.DisassociateWhenNotFound],
            ['Owner account', x.OwnerAccountId],
            ['Last discovery', x.AutomatedDiscoveryInformation?.LastRunTime],
          ]),
        ],
        tables: [
          table(['Resource type', 'Consumed'], (x.ConsumedLicenseSummaryList || []).map((s) => [s.ResourceType, s.ConsumedLicenses]), { title: 'Consumption by resource type', emptyMessage: 'Nothing consumed' }),
          table(['Resource type', 'Filters'], (x.ProductInformationList || []).map((p) => [p.ResourceType, (p.ProductInformationFilterList || []).map((f) => `${f.ProductInformationFilterName} ${f.ProductInformationFilterComparator} ${(f.ProductInformationFilterValue || []).join('|')}`)]), { title: 'Automated discovery rules', emptyMessage: 'No discovery rules' }),
        ],
      }),
      tab('Usage', {
        tables: [table(['Resource', 'Type', 'Status', 'Owner', 'Consumed', 'Associated'], (parts.usage || []).map((u) => [u.ResourceArn, u.ResourceType, u.ResourceStatus, u.ResourceOwnerId, u.ConsumedLicenses, u.AssociationTime]), { statusColumn: 2, emptyMessage: 'Not used by any resource' })],
      }),
      tab('Associations', {
        tables: [table(['Resource', 'Type', 'Owner', 'Associated', 'AMI scope'], (parts.assocs || []).map((a) => [a.ResourceArn, a.ResourceType, a.ResourceOwnerId, a.AssociationTime, a.AmiAssociationScope]), { emptyMessage: 'No associations' })],
      }),
    ],
    tags: tagList(x.Tags),
    actions: [],
    errors,
  };
}

async function licensePage(c: LicenseManagerClient, id: string, arn: string): Promise<ResourcePage> {
  const l = (await received(c, [arn]))[0];
  if (!l) throw httpError(`License not found: ${arn}`, 404);
  return {
    id,
    title: l.LicenseName || arn,
    subtitle: l.ProductName || 'Granted license',
    status: l.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('License', [
            ['Product', l.ProductName],
            ['SKU', l.ProductSKU],
            ['Issuer', l.Issuer?.Name],
            ['Beneficiary', l.Beneficiary],
            ['Home region', l.HomeRegion],
            ['Status', l.Status],
            ['Valid from', l.Validity?.Begin],
            ['Valid until', l.Validity?.End],
            ['Version', l.Version],
            ['Received status', l.ReceivedMetadata?.ReceivedStatus],
            ['Allowed operations', l.ReceivedMetadata?.AllowedOperations],
          ]),
        ],
        tables: [
          table(['Entitlement', 'Unit', 'Value', 'Max', 'Overage'], (l.Entitlements || []).map((e) => [e.Name, e.Unit, e.Value, e.MaxCount, e.Overage]), { title: 'Entitlements', emptyMessage: 'No entitlements' }),
          table(['Key', 'Value'], (l.LicenseMetadata || []).map((m) => [m.Name, m.Value]), { title: 'Metadata', emptyMessage: 'No metadata' }),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function grantPage(c: LicenseManagerClient, id: string, arn: string): Promise<ResourcePage> {
  const g = (await grants(c, [arn]))[0];
  if (!g) throw httpError(`Grant not found: ${arn}`, 404);
  return {
    id,
    title: g.GrantName || arn,
    subtitle: 'Received grant',
    status: g.GrantStatus,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Grant', [
            ['License', g.LicenseArn],
            ['Grantee', g.GranteePrincipalArn],
            ['Parent', g.ParentArn],
            ['Home region', g.HomeRegion],
            ['Status', g.GrantStatus],
            ['Status reason', g.StatusReason],
            ['Operations', g.GrantedOperations],
            ['Activation override', g.Options?.ActivationOverrideBehavior],
            ['Version', g.Version],
          ], { note: 'Accept, reject or activate grants in the License Manager console.' }),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'cfg') return configPage(c, id, arn);
  if (kind === 'lic') return licensePage(c, id, arn);
  if (kind === 'grant') return grantPage(c, id, arn);
  throw httpError(`Unknown License Manager page: ${id}`, 400);
}

function taggable(id: string) {
  const [kind, arn] = splitId(id);
  if (kind !== 'cfg') throw httpError('Only self-managed licenses can be tagged here', 400);
  return arn;
}

export const licenseManagerAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: taggable(id), Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: taggable(id), TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('cfg:'),
};
