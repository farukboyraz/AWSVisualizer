import {
  WAFV2Client,
  ListWebACLsCommand,
  ListIPSetsCommand,
  ListRegexPatternSetsCommand,
  ListRuleGroupsCommand,
  GetWebACLCommand,
  GetIPSetCommand,
  GetRegexPatternSetCommand,
  GetRuleGroupCommand,
  GetLoggingConfigurationCommand,
  ListResourcesForWebACLCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Rule,
  type Statement,
  type Scope,
} from '@aws-sdk/client-wafv2';
import {
  ShieldClient,
  DescribeSubscriptionCommand,
  ListProtectionsCommand,
  DescribeProtectionCommand,
  ListTagsForResourceCommand as ShieldTagsCommand,
  TagResourceCommand as ShieldTagCommand,
  UntagResourceCommand as ShieldUntagCommand,
} from '@aws-sdk/client-shield';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTable } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, isNotEnabled } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** CloudFront-scoped WAF resources (and Shield) live in us-east-1. */
const GLOBAL_REGION = 'us-east-1';
const waf = (p: string, scope: Scope, r: string) => new WAFV2Client({ region: scope === 'CLOUDFRONT' ? GLOBAL_REGION : r, credentials: cachedCredentials(p) });
const shield = (p: string) => new ShieldClient({ region: GLOBAL_REGION, credentials: cachedCredentials(p) });

const marker = (r: { NextMarker?: string }) => r.NextMarker;
const scopeLabel = (s: Scope) => (s === 'CLOUDFRONT' ? 'CloudFront (global)' : 'Regional');

/** ids look like `acl:REGIONAL|name|id`. */
const parse = (rest: string) => {
  const [scope, name, wafId] = rest.split('|');
  if (scope !== 'REGIONAL' && scope !== 'CLOUDFRONT') throw httpError(`Bad WAF id: ${rest}`, 400);
  return { scope: scope as Scope, name, wafId };
};

async function listScope(profile: string, region: string, scope: Scope): Promise<PageSummary[]> {
  const c = waf(profile, scope, region);
  const [acls, ipSets, regexSets, groups] = await Promise.all([
    pageAll((NextMarker) => c.send(new ListWebACLsCommand({ Scope: scope, NextMarker, Limit: 100 })), (r) => r.WebACLs, marker),
    pageAll((NextMarker) => c.send(new ListIPSetsCommand({ Scope: scope, NextMarker, Limit: 100 })), (r) => r.IPSets, marker),
    pageAll((NextMarker) => c.send(new ListRegexPatternSetsCommand({ Scope: scope, NextMarker, Limit: 100 })), (r) => r.RegexPatternSets, marker),
    pageAll((NextMarker) => c.send(new ListRuleGroupsCommand({ Scope: scope, NextMarker, Limit: 100 })), (r) => r.RuleGroups, marker),
  ]);
  const row = (kind: string, group: string) => (x: { Name?: string; Id?: string; Description?: string }) => ({
    id: `${kind}:${scope}|${x.Name}|${x.Id}`,
    name: x.Name || '',
    group: `${group} · ${scopeLabel(scope)}`,
    info: x.Description || x.Id,
  });
  return [...acls.map(row('acl', 'Web ACLs')), ...groups.map(row('rg', 'Rule groups')), ...ipSets.map(row('ip', 'IP sets')), ...regexSets.map(row('re', 'Regex pattern sets'))];
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const [regional, global, protections] = await Promise.all([
    listScope(profile, region, 'REGIONAL'),
    // CloudFront scope needs us-east-1 permissions; a failure there shouldn't hide the regional resources.
    listScope(profile, region, 'CLOUDFRONT').catch(() => []),
    pageAll((NextToken) => shield(profile).send(new ListProtectionsCommand({ NextToken })), (r) => r.Protections, (r) => r.NextToken).catch(() => []),
  ]);
  const order = (g?: string) => (g?.startsWith('Web ACLs') ? 0 : g?.startsWith('Rule groups') ? 1 : g?.startsWith('IP sets') ? 2 : 3);
  const waRows = [...regional, ...global].sort((a, b) => order(a.group) - order(b.group) || (a.group || '').localeCompare(b.group || '') || a.name.localeCompare(b.name));
  return [
    ...waRows,
    { id: 'shield:', name: 'Shield', group: 'Shield', info: protections.length ? `${protections.length} protected resources` : 'Standard protection / Advanced subscription' },
    ...protections.map((p) => ({ id: `prot:${p.Id}`, name: p.Name || p.Id || '', group: 'Shield Advanced protections', info: p.ResourceArn })),
  ];
}

/** Short, readable description of a rule's top-level statement. */
function statementText(s?: Statement): string {
  if (!s) return '-';
  if (s.ManagedRuleGroupStatement) return `Managed group ${s.ManagedRuleGroupStatement.VendorName}/${s.ManagedRuleGroupStatement.Name}${s.ManagedRuleGroupStatement.Version ? ` ${s.ManagedRuleGroupStatement.Version}` : ''}`;
  if (s.RuleGroupReferenceStatement) return `Rule group ${s.RuleGroupReferenceStatement.ARN?.split('/').slice(-2, -1)[0] ?? ''}`;
  if (s.RateBasedStatement) return `Rate limit ${s.RateBasedStatement.Limit} / ${s.RateBasedStatement.EvaluationWindowSec ?? 300}s by ${s.RateBasedStatement.AggregateKeyType}`;
  if (s.IPSetReferenceStatement) return `IP set ${s.IPSetReferenceStatement.ARN?.split('/').slice(-2, -1)[0] ?? ''}`;
  if (s.GeoMatchStatement) return `Country in ${(s.GeoMatchStatement.CountryCodes || []).join(', ')}`;
  if (s.ByteMatchStatement) return `String match (${s.ByteMatchStatement.PositionalConstraint})`;
  if (s.RegexPatternSetReferenceStatement) return 'Regex pattern set';
  if (s.SqliMatchStatement) return 'SQL injection match';
  if (s.XssMatchStatement) return 'XSS match';
  if (s.SizeConstraintStatement) return `Size ${s.SizeConstraintStatement.ComparisonOperator} ${s.SizeConstraintStatement.Size}`;
  if (s.LabelMatchStatement) return `Label ${s.LabelMatchStatement.Key}`;
  if (s.AndStatement) return `AND of ${s.AndStatement.Statements?.length ?? 0}`;
  if (s.OrStatement) return `OR of ${s.OrStatement.Statements?.length ?? 0}`;
  if (s.NotStatement) return `NOT (${statementText(s.NotStatement.Statement)})`;
  return Object.keys(s)[0] ?? '-';
}

const actionText = (r: Rule) =>
  r.Action ? Object.keys(r.Action)[0] : r.OverrideAction ? (r.OverrideAction.Count ? 'Override to count' : 'Use rule group actions') : '-';

const rulesTable = (rules?: Rule[]): PageTable =>
  table(
    ['Priority', 'Rule', 'Action', 'Statement', 'CloudWatch metric'],
    [...(rules || [])].sort((a, b) => (a.Priority ?? 0) - (b.Priority ?? 0)).map((r) => [r.Priority, r.Name, actionText(r), statementText(r.Statement), r.VisibilityConfig?.MetricName]),
    { emptyMessage: 'No rules' },
  );

async function tagsFor(c: WAFV2Client, arn?: string) {
  if (!arn) return [];
  return (await c.send(new ListTagsForResourceCommand({ ResourceARN: arn }))).TagInfoForResource?.TagList;
}

async function aclPage(c: WAFV2Client, id: string, scope: Scope, name: string, wafId: string): Promise<ResourcePage> {
  const acl = (await c.send(new GetWebACLCommand({ Scope: scope, Name: name, Id: wafId }))).WebACL;
  if (!acl) throw httpError(`Web ACL not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      tags: tagsFor(c, acl.ARN),
      // ListResourcesForWebACL only covers regional resources (CloudFront distributions reference the ACL themselves).
      resources: scope === 'REGIONAL' ? c.send(new ListResourcesForWebACLCommand({ WebACLArn: acl.ARN })) : Promise.resolve(undefined),
      logging: c.send(new GetLoggingConfigurationCommand({ ResourceArn: acl.ARN })),
    },
    errors,
    (err) => (err as { name?: string })?.name === 'WAFNonexistentItemException',
  );
  const log = parts.logging?.LoggingConfiguration;
  return {
    id,
    title: name,
    subtitle: `Web ACL · ${scopeLabel(scope)}`,
    arn: acl.ARN,
    tabs: [
      tab('Overview', {
        sections: [
          section('Web ACL', [
            ['Name', acl.Name],
            ['ID', acl.Id],
            ['Description', acl.Description],
            ['Scope', scopeLabel(scope)],
            ['Default action', acl.DefaultAction?.Allow ? 'Allow' : acl.DefaultAction?.Block ? 'Block' : undefined],
            ['Capacity (WCUs)', acl.Capacity],
            ['Label namespace', acl.LabelNamespace],
            ['Managed by Firewall Manager', acl.ManagedByFirewallManager],
            ['CloudWatch metric', acl.VisibilityConfig?.MetricName],
            ['Sampled requests', acl.VisibilityConfig?.SampledRequestsEnabled],
            ['Logging', log ? log.LogDestinationConfigs : 'Disabled'],
          ]),
        ],
      }),
      tab('Rules', { tables: [rulesTable(acl.Rules)] }),
      tab('Associated resources', {
        tables: [table(['Resource ARN'], (parts.resources?.ResourceArns || []).map((a) => [a]), { emptyMessage: scope === 'CLOUDFRONT' ? 'CloudFront distributions reference the web ACL in their own settings' : 'Not associated with any resource' })],
      }),
      tab('JSON', { json: JSON.stringify(acl, null, 2) }),
    ],
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function ruleGroupPage(c: WAFV2Client, id: string, scope: Scope, name: string, wafId: string): Promise<ResourcePage> {
  const g = (await c.send(new GetRuleGroupCommand({ Scope: scope, Name: name, Id: wafId }))).RuleGroup;
  if (!g) throw httpError(`Rule group not found: ${name}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: tagsFor(c, g.ARN) }, errors);
  return {
    id,
    title: name,
    subtitle: `Rule group · ${scopeLabel(scope)}`,
    arn: g.ARN,
    tabs: [
      tab('Overview', { sections: [section('Rule group', [['Name', g.Name], ['ID', g.Id], ['Description', g.Description], ['Capacity (WCUs)', g.Capacity], ['Label namespace', g.LabelNamespace], ['CloudWatch metric', g.VisibilityConfig?.MetricName]])] }),
      tab('Rules', { tables: [rulesTable(g.Rules)] }),
      tab('JSON', { json: JSON.stringify(g, null, 2) }),
    ],
    tags: tagList(tags),
    actions: [],
    errors,
  };
}

async function ipSetPage(c: WAFV2Client, id: string, scope: Scope, name: string, wafId: string): Promise<ResourcePage> {
  const s = (await c.send(new GetIPSetCommand({ Scope: scope, Name: name, Id: wafId }))).IPSet;
  if (!s) throw httpError(`IP set not found: ${name}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: tagsFor(c, s.ARN) }, errors);
  return {
    id,
    title: name,
    subtitle: `IP set · ${scopeLabel(scope)}`,
    arn: s.ARN,
    tabs: [
      tab('Overview', { sections: [section('IP set', [['Name', s.Name], ['ID', s.Id], ['Description', s.Description], ['IP version', s.IPAddressVersion], ['Addresses', s.Addresses?.length ?? 0]])] }),
      tab('Addresses', { tables: [table(['Address'], (s.Addresses || []).map((a) => [a]), { emptyMessage: 'No addresses' })] }),
    ],
    tags: tagList(tags),
    actions: [],
    errors,
  };
}

async function regexSetPage(c: WAFV2Client, id: string, scope: Scope, name: string, wafId: string): Promise<ResourcePage> {
  const s = (await c.send(new GetRegexPatternSetCommand({ Scope: scope, Name: name, Id: wafId }))).RegexPatternSet;
  if (!s) throw httpError(`Regex pattern set not found: ${name}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: tagsFor(c, s.ARN) }, errors);
  return {
    id,
    title: name,
    subtitle: `Regex pattern set · ${scopeLabel(scope)}`,
    arn: s.ARN,
    tabs: [
      tab('Overview', { sections: [section('Regex pattern set', [['Name', s.Name], ['ID', s.Id], ['Description', s.Description]])] }),
      tab('Patterns', { tables: [table(['Regular expression'], (s.RegularExpressionList || []).map((r) => [r.RegexString]), { emptyMessage: 'No patterns' })] }),
    ],
    tags: tagList(tags),
    actions: [],
    errors,
  };
}

async function shieldPage(profile: string, id: string): Promise<ResourcePage> {
  const errors: string[] = [];
  const sub = await shield(profile)
    .send(new DescribeSubscriptionCommand({}))
    .then((r) => r.Subscription)
    .catch((err) => {
      if (!isNotEnabled(err)) errors.push(`Subscription: ${err.message}`);
      return undefined;
    });
  return {
    id,
    title: 'AWS Shield',
    subtitle: sub ? 'Shield Advanced' : 'Shield Standard',
    status: sub ? 'ACTIVE' : undefined,
    tabs: [
      tab('Overview', {
        sections: [
          sub
            ? section('Shield Advanced subscription', [
                ['Start', sub.StartTime],
                ['End', sub.EndTime],
                ['Commitment', sub.TimeCommitmentInSeconds !== undefined ? `${Math.round(sub.TimeCommitmentInSeconds / 86400)} days` : undefined],
                ['Auto renew', sub.AutoRenew],
                ['Proactive engagement', sub.ProactiveEngagementStatus],
                ['Subscription ARN', sub.SubscriptionArn],
              ])
            : section('Shield Standard', [['Status', 'Automatically on for every AWS account (no configuration)']], {
                note: 'Shield Advanced (paid) adds protected resources, DDoS response team access and cost protection. This account has no Shield Advanced subscription.',
              }),
        ],
        tables: sub ? [table(['Limit', 'Max'], (sub.SubscriptionLimits?.ProtectionLimits?.ProtectedResourceTypeLimits || []).map((l) => [l.Type, l.Max]), { title: 'Protection limits' })] : [],
      }),
    ],
    actions: [],
    errors,
  };
}

async function protectionPage(profile: string, id: string, protId: string): Promise<ResourcePage> {
  const c = shield(profile);
  const p = (await c.send(new DescribeProtectionCommand({ ProtectionId: protId }))).Protection;
  if (!p) throw httpError(`Protection not found: ${protId}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ShieldTagsCommand({ ResourceARN: p.ProtectionArn })) }, errors);
  return {
    id,
    title: p.Name || protId,
    subtitle: p.ResourceArn,
    arn: p.ProtectionArn,
    tabs: [
      tab('Overview', {
        sections: [
          section('Protection', [
            ['Protection ID', p.Id],
            ['Resource', p.ResourceArn],
            ['Health checks', p.HealthCheckIds],
            ['Automatic application-layer mitigation', p.ApplicationLayerAutomaticResponseConfiguration?.Status],
          ]),
        ],
      }),
    ],
    tags: tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'shield') return shieldPage(profile, id);
  if (kind === 'prot') return protectionPage(profile, id, rest);
  const { scope, name, wafId } = parse(rest);
  const c = waf(profile, scope, region);
  if (kind === 'acl') return aclPage(c, id, scope, name, wafId);
  if (kind === 'rg') return ruleGroupPage(c, id, scope, name, wafId);
  if (kind === 'ip') return ipSetPage(c, id, scope, name, wafId);
  if (kind === 're') return regexSetPage(c, id, scope, name, wafId);
  throw httpError(`Unknown WAF resource: ${id}`, 400);
}

export const wafAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    const [kind, rest] = splitId(id);
    if (kind === 'prot') return void (await shield(profile).send(new ShieldTagCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] })));
    if (kind === 'shield') throw httpError('Shield subscription has no tags', 400);
    await waf(profile, parse(rest).scope, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    const [kind, rest] = splitId(id);
    if (kind === 'prot') return void (await shield(profile).send(new ShieldUntagCommand({ ResourceARN: arn, TagKeys: [key] })));
    if (kind === 'shield') throw httpError('Shield subscription has no tags', 400);
    await waf(profile, parse(rest).scope, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('acl:'),
};
