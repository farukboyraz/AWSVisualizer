import {
  NetworkFirewallClient,
  ListFirewallsCommand,
  ListFirewallPoliciesCommand,
  ListRuleGroupsCommand,
  DescribeFirewallCommand,
  DescribeFirewallPolicyCommand,
  DescribeRuleGroupCommand,
  DescribeLoggingConfigurationCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-network-firewall';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new NetworkFirewallClient({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [fws, policies, groups] = await Promise.all([
    pageAll((NextToken) => c.send(new ListFirewallsCommand({ NextToken })), (r) => r.Firewalls, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListFirewallPoliciesCommand({ NextToken })), (r) => r.FirewallPolicies, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListRuleGroupsCommand({ NextToken })), (r) => r.RuleGroups, (r) => r.NextToken),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...fws.map((f) => ({ id: `fw:${f.FirewallArn}`, name: f.FirewallName || '', group: 'Firewalls', info: f.FirewallArn })).sort(byName),
    ...policies.map((p) => ({ id: `pol:${p.Arn}`, name: p.Name || '', group: 'Firewall policies', info: p.Arn })).sort(byName),
    ...groups.map((g) => ({ id: `rg:${g.Arn}`, name: g.Name || '', group: 'Rule groups', info: g.Arn })).sort(byName),
  ];
}

async function firewallPage(c: NetworkFirewallClient, id: string, arn: string): Promise<ResourcePage> {
  const res = await c.send(new DescribeFirewallCommand({ FirewallArn: arn }));
  const f = res.Firewall;
  if (!f) throw httpError(`Firewall not found: ${arn}`, 404);
  const st = res.FirewallStatus;
  const errors: string[] = [];
  const { logging } = await settle({ logging: c.send(new DescribeLoggingConfigurationCommand({ FirewallArn: arn })) }, errors);
  return {
    id,
    title: f.FirewallName || arn,
    subtitle: f.Description || `Firewall · ${f.VpcId}`,
    status: st?.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Firewall', [
            ['Name', f.FirewallName],
            ['Description', f.Description],
            ['VPC', f.VpcId],
            ['Firewall policy', f.FirewallPolicyArn],
            ['Status', st?.Status],
            ['Configuration sync', st?.ConfigurationSyncStateSummary],
            ['Delete protection', f.DeleteProtection],
            ['Policy change protection', f.FirewallPolicyChangeProtection],
            ['Subnet change protection', f.SubnetChangeProtection],
            ['Encryption', f.EncryptionConfiguration?.Type],
            ['Owner', f.FirewallId && arn.split(':')[4]],
          ]),
        ],
      }),
      tab('Firewall endpoints', {
        tables: [
          table(
            ['Availability zone', 'Subnet', 'Endpoint', 'Status'],
            Object.entries(st?.SyncStates || {}).map(([az, s]) => [az, s.Attachment?.SubnetId, s.Attachment?.EndpointId, s.Attachment?.Status]),
            { statusColumn: 3, emptyMessage: 'No subnets' },
          ),
        ],
      }),
      tab('Logging', {
        tables: [
          table(
            ['Log type', 'Destination type', 'Destination'],
            (logging?.LoggingConfiguration?.LogDestinationConfigs || []).map((l) => [l.LogType, l.LogDestinationType, Object.values(l.LogDestination || {}).join(', ')]),
            { emptyMessage: 'Logging is not configured' },
          ),
        ],
      }),
    ],
    tags: tagList(f.Tags),
    actions: [],
    errors,
  };
}

async function policyPage(c: NetworkFirewallClient, id: string, arn: string): Promise<ResourcePage> {
  const res = await c.send(new DescribeFirewallPolicyCommand({ FirewallPolicyArn: arn }));
  const meta = res.FirewallPolicyResponse;
  const p = res.FirewallPolicy;
  return {
    id,
    title: meta?.FirewallPolicyName || arn,
    subtitle: meta?.Description || 'Firewall policy',
    status: meta?.FirewallPolicyStatus,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Policy', [
            ['Name', meta?.FirewallPolicyName],
            ['Description', meta?.Description],
            ['Firewalls using it', meta?.NumberOfAssociations],
            ['Stateless default actions', p?.StatelessDefaultActions],
            ['Stateless fragment default actions', p?.StatelessFragmentDefaultActions],
            ['Stateful rule order', p?.StatefulEngineOptions?.RuleOrder],
            ['Stream exception policy', p?.StatefulEngineOptions?.StreamExceptionPolicy],
            ['Stateful default actions', p?.StatefulDefaultActions],
            ['TLS inspection', p?.TLSInspectionConfigurationArn],
            ['Consumed stateless capacity', meta?.ConsumedStatelessRuleCapacity],
            ['Consumed stateful capacity', meta?.ConsumedStatefulRuleCapacity],
            ['Last modified', meta?.LastModifiedTime],
          ]),
        ],
        tables: [
          table(['Priority', 'Stateless rule group'], (p?.StatelessRuleGroupReferences || []).map((r) => [r.Priority, r.ResourceArn]), { title: 'Stateless rule groups', emptyMessage: 'None' }),
          table(['Priority', 'Stateful rule group', 'Override'], (p?.StatefulRuleGroupReferences || []).map((r) => [r.Priority, r.ResourceArn, r.Override?.Action]), { title: 'Stateful rule groups', emptyMessage: 'None' }),
        ],
      }),
      tab('JSON', { json: JSON.stringify(p, null, 2) }),
    ],
    tags: tagList(meta?.Tags),
    actions: [],
    errors: [],
  };
}

async function ruleGroupPage(c: NetworkFirewallClient, id: string, arn: string): Promise<ResourcePage> {
  const res = await c.send(new DescribeRuleGroupCommand({ RuleGroupArn: arn }));
  const meta = res.RuleGroupResponse;
  const rs = res.RuleGroup?.RulesSource;
  const tabs = [
    tab('Details', {
      sections: [
        section('Rule group', [
          ['Name', meta?.RuleGroupName],
          ['Description', meta?.Description],
          ['Type', meta?.Type],
          ['Capacity', meta?.Capacity],
          ['Consumed capacity', meta?.ConsumedCapacity],
          ['Used by policies', meta?.NumberOfAssociations],
          ['Managed source', meta?.SourceMetadata?.SourceArn],
          ['Last modified', meta?.LastModifiedTime],
        ]),
      ],
      tables: rs?.StatefulRules
        ? [
            table(
              ['Action', 'Protocol', 'Source', 'Source port', 'Direction', 'Destination', 'Destination port'],
              rs.StatefulRules.map((r) => [r.Action, r.Header?.Protocol, r.Header?.Source, r.Header?.SourcePort, r.Header?.Direction, r.Header?.Destination, r.Header?.DestinationPort]),
              { title: 'Stateful rules' },
            ),
          ]
        : rs?.RulesSourceList
          ? [table(['Domain'], (rs.RulesSourceList.Targets || []).map((t) => [t]), { title: `Domain list · ${rs.RulesSourceList.GeneratedRulesType} (${(rs.RulesSourceList.TargetTypes || []).join(', ')})` })]
          : [],
    }),
  ];
  if (rs?.RulesString) tabs.push(tab('Suricata rules', { text: rs.RulesString }));
  tabs.push(tab('JSON', { json: JSON.stringify(res.RuleGroup, null, 2) }));
  return { id, title: meta?.RuleGroupName || arn, subtitle: `${meta?.Type ?? ''} rule group`, status: meta?.RuleGroupStatus, arn, tabs, tags: tagList(meta?.Tags), actions: [], errors: [] };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'fw') return firewallPage(c, id, arn);
  if (kind === 'pol') return policyPage(c, id, arn);
  if (kind === 'rg') return ruleGroupPage(c, id, arn);
  throw httpError(`Unknown Network Firewall resource: ${id}`, 400);
}

export const networkFirewallAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: splitId(id)[1], Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: splitId(id)[1], TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('fw:'),
};
