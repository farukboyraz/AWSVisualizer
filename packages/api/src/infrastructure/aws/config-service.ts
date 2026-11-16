import {
  ConfigServiceClient,
  DescribeConfigurationRecordersCommand,
  DescribeConfigurationRecorderStatusCommand,
  DescribeDeliveryChannelsCommand,
  DescribeDeliveryChannelStatusCommand,
  DescribeConfigRulesCommand,
  DescribeComplianceByConfigRuleCommand,
  DescribeConfigRuleEvaluationStatusCommand,
  GetComplianceDetailsByConfigRuleCommand,
  DescribeConformancePacksCommand,
  DescribeConformancePackComplianceCommand,
  DescribeConfigurationAggregatorsCommand,
  DescribeConfigurationAggregatorSourcesStatusCommand,
  GetDiscoveredResourceCountsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-config-service';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ConfigServiceClient({ region: r, credentials: cachedCredentials(p) });

const EVALUATION_LIMIT = 200;

async function rules(c: ConfigServiceClient, names?: string[]) {
  return pageAll((NextToken) => c.send(new DescribeConfigRulesCommand({ NextToken, ConfigRuleNames: names })), (r) => r.ConfigRules, (r) => r.NextToken);
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [recorders, recorderStatus, allRules, compliance, packs, aggregators] = await Promise.all([
    c.send(new DescribeConfigurationRecordersCommand({})).then((r) => r.ConfigurationRecorders || []),
    c.send(new DescribeConfigurationRecorderStatusCommand({})).then((r) => r.ConfigurationRecordersStatus || []).catch(() => []),
    rules(c),
    pageAll((NextToken) => c.send(new DescribeComplianceByConfigRuleCommand({ NextToken })), (r) => r.ComplianceByConfigRules, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeConformancePacksCommand({ NextToken })), (r) => r.ConformancePackDetails, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeConfigurationAggregatorsCommand({ NextToken })), (r) => r.ConfigurationAggregators, (r) => r.NextToken).catch(() => []),
  ]);
  const ruleCompliance = new Map(compliance.map((x) => [x.ConfigRuleName, x.Compliance?.ComplianceType]));
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...recorders.map((r) => {
      const st = recorderStatus.find((s) => s.name === r.name);
      return { id: `rec:${r.name}`, name: r.name || 'default', group: 'Recorder', status: st ? (st.recording ? 'RECORDING' : 'STOPPED') : undefined, info: r.recordingGroup?.allSupported ? 'All supported resource types' : `${r.recordingGroup?.resourceTypes?.length ?? 0} resource types` };
    }),
    ...allRules.map((r) => ({ id: `rule:${r.ConfigRuleName}`, name: r.ConfigRuleName || '', group: 'Rules', status: ruleCompliance.get(r.ConfigRuleName) || r.ConfigRuleState, info: r.Source?.Owner === 'AWS' ? `AWS managed · ${r.Source.SourceIdentifier}` : `${r.Source?.Owner ?? 'Custom'} rule` })).sort(byName),
    ...packs.map((p) => ({ id: `pack:${p.ConformancePackName}`, name: p.ConformancePackName || '', group: 'Conformance packs', info: p.CreatedBy ? `Created by ${p.CreatedBy}` : 'Conformance pack' })).sort(byName),
    ...aggregators.map((a) => ({ id: `agg:${a.ConfigurationAggregatorName}`, name: a.ConfigurationAggregatorName || '', group: 'Aggregators', info: a.OrganizationAggregationSource ? 'Organization' : `${a.AccountAggregationSources?.[0]?.AccountIds?.length ?? 0} accounts` })).sort(byName),
  ];
}

async function recorderPage(c: ConfigServiceClient, id: string, name: string): Promise<ResourcePage> {
  const r = (await c.send(new DescribeConfigurationRecordersCommand({ ConfigurationRecorderNames: [name] }))).ConfigurationRecorders?.[0];
  if (!r) throw httpError(`Configuration recorder not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      status: c.send(new DescribeConfigurationRecorderStatusCommand({ ConfigurationRecorderNames: [name] })),
      channels: c.send(new DescribeDeliveryChannelsCommand({})),
      channelStatus: c.send(new DescribeDeliveryChannelStatusCommand({})),
      counts: pageAll((nextToken) => c.send(new GetDiscoveredResourceCountsCommand({ nextToken })), (x) => x.resourceCounts, (x) => x.nextToken),
    },
    errors,
  );
  const st = parts.status?.ConfigurationRecordersStatus?.[0];
  const g = r.recordingGroup;
  return {
    id,
    title: r.name || 'Configuration recorder',
    subtitle: 'AWS Config recorder',
    status: st ? (st.recording ? 'RECORDING' : 'STOPPED') : undefined,
    tabs: [
      tab('Recorder', {
        sections: [
          section('Recording', [
            ['Recording', st?.recording],
            ['Last status', st?.lastStatus],
            ['Last error', st?.lastErrorMessage],
            ['Last started', st?.lastStartTime],
            ['Last stopped', st?.lastStopTime],
            ['Role', r.roleARN],
            ['Recording frequency', r.recordingMode?.recordingFrequency],
          ]),
          section('Resource types', [
            ['All supported', g?.allSupported],
            ['Include global resources', g?.includeGlobalResourceTypes],
            ['Strategy', g?.recordingStrategy?.useOnly],
            ['Resource types', g?.resourceTypes],
            ['Excluded types', g?.exclusionByResourceTypes?.resourceTypes],
          ]),
        ],
        tables: [
          table(
            ['Delivery channel', 'S3 bucket', 'S3 prefix', 'SNS topic', 'Snapshot frequency', 'Last delivery'],
            (parts.channels?.DeliveryChannels || []).map((d) => {
              const ds = parts.channelStatus?.DeliveryChannelsStatus?.find((x) => x.name === d.name);
              return [d.name, d.s3BucketName, d.s3KeyPrefix, d.snsTopicARN, d.configSnapshotDeliveryProperties?.deliveryFrequency, ds?.configHistoryDeliveryInfo?.lastStatus];
            }),
            { title: 'Delivery channels', emptyMessage: 'No delivery channel' },
          ),
        ],
      }),
      tab('Inventory', {
        tables: [
          table(
            ['Resource type', 'Count'],
            (parts.counts || []).sort((a, b) => (b.count ?? 0) - (a.count ?? 0)).map((x) => [x.resourceType, x.count]),
            { title: `${(parts.counts || []).reduce((n, x) => n + (x.count ?? 0), 0)} recorded resources`, emptyMessage: 'Nothing recorded yet' },
          ),
        ],
      }),
    ],
    actions: [],
    errors,
  };
}

async function rulePage(c: ConfigServiceClient, id: string, name: string): Promise<ResourcePage> {
  const r = (await rules(c, [name]))[0];
  if (!r) throw httpError(`Config rule not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      compliance: c.send(new DescribeComplianceByConfigRuleCommand({ ConfigRuleNames: [name] })),
      evalStatus: c.send(new DescribeConfigRuleEvaluationStatusCommand({ ConfigRuleNames: [name] })),
      results: pageAll(
        (NextToken) => c.send(new GetComplianceDetailsByConfigRuleCommand({ ConfigRuleName: name, NextToken, ComplianceTypes: ['NON_COMPLIANT', 'COMPLIANT'], Limit: 100 })),
        (x) => x.EvaluationResults,
        (x) => x.NextToken,
        EVALUATION_LIMIT,
      ),
      tags: r.ConfigRuleArn ? c.send(new ListTagsForResourceCommand({ ResourceArn: r.ConfigRuleArn })) : Promise.resolve(undefined),
    },
    errors,
  );
  const comp = parts.compliance?.ComplianceByConfigRules?.[0]?.Compliance;
  const ev = parts.evalStatus?.ConfigRulesEvaluationStatus?.[0];
  const results = (parts.results || []).sort((a, b) => (a.ComplianceType === 'NON_COMPLIANT' ? -1 : 0) - (b.ComplianceType === 'NON_COMPLIANT' ? -1 : 0));
  return {
    id,
    title: name,
    subtitle: r.Description || 'Config rule',
    status: comp?.ComplianceType || r.ConfigRuleState,
    arn: r.ConfigRuleArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Rule', [
            ['Name', r.ConfigRuleName],
            ['State', r.ConfigRuleState],
            ['Compliance', comp?.ComplianceType],
            ['Non-compliant resources', comp?.ComplianceContributorCount?.CappedCount],
            ['Source', r.Source?.Owner],
            ['Identifier', r.Source?.SourceIdentifier],
            ['Trigger', (r.Source?.SourceDetails || []).map((d) => d.MessageType)],
            ['Periodic frequency', r.MaximumExecutionFrequency],
            ['Scope (resource types)', r.Scope?.ComplianceResourceTypes],
            ['Scope (tag)', r.Scope?.TagKey && `${r.Scope.TagKey}=${r.Scope.TagValue ?? '*'}`],
            ['Created by', r.CreatedBy],
            ['Evaluation mode', (r.EvaluationModes || []).map((m) => m.Mode)],
          ]),
          section('Last evaluation', [
            ['Last successful', ev?.LastSuccessfulEvaluationTime],
            ['Last failed', ev?.LastFailedEvaluationTime],
            ['Last error', ev?.LastErrorMessage],
            ['First activated', ev?.FirstActivatedTime],
          ]),
        ],
      }),
      tab('Resources in scope', {
        tables: [
          table(
            ['Resource', 'Type', 'Compliance', 'Annotation', 'Evaluated'],
            results.map((x) => [x.EvaluationResultIdentifier?.EvaluationResultQualifier?.ResourceId, x.EvaluationResultIdentifier?.EvaluationResultQualifier?.ResourceType, x.ComplianceType, x.Annotation, x.ResultRecordedTime]),
            { statusColumn: 2, title: results.length >= EVALUATION_LIMIT ? `First ${EVALUATION_LIMIT} results` : undefined, emptyMessage: 'No evaluation results yet' },
          ),
        ],
      }),
      ...(r.InputParameters ? [tab('Parameters', { json: JSON.stringify(JSON.parse(r.InputParameters), null, 2) })] : []),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function packPage(c: ConfigServiceClient, id: string, name: string): Promise<ResourcePage> {
  const p = (await c.send(new DescribeConformancePacksCommand({ ConformancePackNames: [name] }))).ConformancePackDetails?.[0];
  if (!p) throw httpError(`Conformance pack not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      compliance: pageAll((NextToken) => c.send(new DescribeConformancePackComplianceCommand({ ConformancePackName: name, NextToken })), (x) => x.ConformancePackRuleComplianceList, (x) => x.NextToken),
      tags: p.ConformancePackArn ? c.send(new ListTagsForResourceCommand({ ResourceArn: p.ConformancePackArn })) : Promise.resolve(undefined),
    },
    errors,
  );
  const nonCompliant = (parts.compliance || []).filter((x) => x.ComplianceType === 'NON_COMPLIANT').length;
  return {
    id,
    title: name,
    subtitle: 'Conformance pack',
    status: parts.compliance ? (nonCompliant ? 'NON_COMPLIANT' : 'COMPLIANT') : undefined,
    arn: p.ConformancePackArn,
    tabs: [
      tab('Details', {
        sections: [section('Conformance pack', [['Name', name], ['Rules', parts.compliance?.length], ['Non-compliant rules', nonCompliant], ['Delivery bucket', p.DeliveryS3Bucket], ['Created by', p.CreatedBy], ['Last update requested', p.LastUpdateRequestedTime]])],
        tables: [table(['Parameter', 'Value'], (p.ConformancePackInputParameters || []).map((x) => [x.ParameterName, x.ParameterValue]), { title: 'Input parameters', emptyMessage: 'No parameters' })],
      }),
      tab('Rules', {
        tables: [table(['Rule', 'Compliance', 'Controls'], (parts.compliance || []).map((x) => [x.ConfigRuleName, x.ComplianceType, x.Controls]), { statusColumn: 1, emptyMessage: 'No rules' })],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function aggregatorPage(c: ConfigServiceClient, id: string, name: string): Promise<ResourcePage> {
  const a = (await c.send(new DescribeConfigurationAggregatorsCommand({ ConfigurationAggregatorNames: [name] }))).ConfigurationAggregators?.[0];
  if (!a) throw httpError(`Aggregator not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      sources: pageAll((NextToken) => c.send(new DescribeConfigurationAggregatorSourcesStatusCommand({ ConfigurationAggregatorName: name, NextToken })), (x) => x.AggregatedSourceStatusList, (x) => x.NextToken),
      tags: a.ConfigurationAggregatorArn ? c.send(new ListTagsForResourceCommand({ ResourceArn: a.ConfigurationAggregatorArn })) : Promise.resolve(undefined),
    },
    errors,
  );
  const org = a.OrganizationAggregationSource;
  const acct = a.AccountAggregationSources?.[0];
  return {
    id,
    title: name,
    subtitle: org ? 'Organization aggregator' : 'Account aggregator',
    arn: a.ConfigurationAggregatorArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Aggregator', [
            ['Name', name],
            ['Source', org ? 'Organization' : 'Individual accounts'],
            ['Role', org?.RoleArn],
            ['All regions', org?.AllAwsRegions ?? acct?.AllAwsRegions],
            ['Regions', org?.AwsRegions ?? acct?.AwsRegions],
            ['Accounts', acct?.AccountIds],
            ['Created by', a.CreatedBy],
            ['Created', a.CreationTime],
            ['Updated', a.LastUpdatedTime],
          ]),
        ],
      }),
      tab('Source status', {
        tables: [
          table(['Source', 'Type', 'Region', 'Status', 'Last updated', 'Error'], (parts.sources || []).map((s) => [s.SourceId, s.SourceType, s.AwsRegion, s.LastUpdateStatus, s.LastUpdateTime, s.LastErrorMessage]), { statusColumn: 3, emptyMessage: 'No sources yet' }),
        ],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  if (kind === 'rec') return recorderPage(c, id, name);
  if (kind === 'rule') return rulePage(c, id, name);
  if (kind === 'pack') return packPage(c, id, name);
  if (kind === 'agg') return aggregatorPage(c, id, name);
  throw httpError(`Unknown Config page: ${id}`, 400);
}

function taggable(id: string, arn: string) {
  if (id.startsWith('rec:') || !arn) throw httpError('The configuration recorder has no tags', 400);
  return arn;
}

export const configAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: taggable(id, arn), Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: taggable(id, arn), TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('rule:'),
};
