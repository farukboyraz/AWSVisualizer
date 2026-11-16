import {
  CloudSearchClient,
  DescribeDomainsCommand,
  DescribeIndexFieldsCommand,
  DescribeScalingParametersCommand,
  DescribeAvailabilityOptionsCommand,
  DescribeServiceAccessPoliciesCommand,
  DescribeSuggestersCommand,
  type IndexField,
} from '@aws-sdk/client-cloudsearch';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, policyJson } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** CloudSearch has no tagging API; pages are read-only. */
const client = (p: string, r: string) => new CloudSearchClient({ region: r, credentials: cachedCredentials(p) });

const state = (d: { Deleted?: boolean; Processing?: boolean; RequiresIndexDocuments?: boolean; Created?: boolean }) =>
  d.Deleted ? 'DELETING' : d.Processing ? 'PROCESSING' : d.RequiresIndexDocuments ? 'NEEDS_INDEXING' : d.Created ? 'ACTIVE' : 'CREATING';

/** The options object that matches the field type (IntOptions, TextOptions…). */
const fieldOptions = (f: IndexField) => {
  const opts = Object.entries(f).find(([k, v]) => k.endsWith('Options') && v)?.[1] as Record<string, unknown> | undefined;
  return Object.entries(opts || {})
    .filter(([, v]) => v === true || (typeof v === 'string' && v))
    .map(([k, v]) => (v === true ? k.replace('Enabled', '') : `${k}=${v}`));
};

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const domains = (await client(profile, region).send(new DescribeDomainsCommand({}))).DomainStatusList || [];
  return domains
    .map((d) => ({ id: `dom:${d.DomainName}`, name: d.DomainName || '', status: state(d), info: `${d.SearchInstanceCount ?? 0}× ${d.SearchInstanceType ?? ''} · ${d.SearchPartitionCount ?? 0} partitions` }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, name] = splitId(id);
  if (kind !== 'dom') throw httpError(`Unknown CloudSearch page: ${id}`, 400);
  const c = client(profile, region);
  const d = (await c.send(new DescribeDomainsCommand({ DomainNames: [name] }))).DomainStatusList?.[0];
  if (!d) throw httpError(`Domain not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      fields: c.send(new DescribeIndexFieldsCommand({ DomainName: name })),
      scaling: c.send(new DescribeScalingParametersCommand({ DomainName: name })),
      availability: c.send(new DescribeAvailabilityOptionsCommand({ DomainName: name })),
      policy: c.send(new DescribeServiceAccessPoliciesCommand({ DomainName: name })),
      suggesters: c.send(new DescribeSuggestersCommand({ DomainName: name })),
    },
    errors,
  );
  const sc = parts.scaling?.ScalingParameters?.Options;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Domain', [
          ['Domain ID', d.DomainId],
          ['State', state(d)],
          ['Search instances', `${d.SearchInstanceCount ?? 0} × ${d.SearchInstanceType ?? '-'}`],
          ['Partitions', d.SearchPartitionCount],
          ['Desired instance type', sc?.DesiredInstanceType],
          ['Desired replication', sc?.DesiredReplicationCount],
          ['Multi-AZ', parts.availability?.AvailabilityOptions?.Options],
          ['Needs indexing', d.RequiresIndexDocuments],
        ]),
        {
          title: 'Endpoints',
          settings: [],
          copyable: [d.SearchService?.Endpoint && { label: 'Search', value: d.SearchService.Endpoint }, d.DocService?.Endpoint && { label: 'Document', value: d.DocService.Endpoint }].filter((x): x is { label: string; value: string } => Boolean(x)),
        },
      ],
    }),
    tab('Index fields', {
      tables: [table(['Field', 'Type', 'Options', 'State'], (parts.fields?.IndexFields || []).map((f) => [f.Options?.IndexFieldName, f.Options?.IndexFieldType, f.Options ? fieldOptions(f.Options) : undefined, f.Status?.State]), { statusColumn: 3, emptyMessage: 'No index fields' })],
    }),
    tab('Suggesters', {
      tables: [table(['Suggester', 'Source field', 'Fuzzy matching'], (parts.suggesters?.Suggesters || []).map((s) => [s.Options?.SuggesterName, s.Options?.DocumentSuggesterOptions?.SourceField, s.Options?.DocumentSuggesterOptions?.FuzzyMatching]), { emptyMessage: 'No suggesters' })],
    }),
  ];
  const policy = policyJson(parts.policy?.AccessPolicies?.Options);
  if (policy) tabs.push(tab('Access policy', { json: policy }));
  return { id, title: name, subtitle: 'CloudSearch domain', status: state(d), arn: d.ARN, tabs, actions: [], errors };
}

export const cloudSearchAdapter: PageServiceAdapter = { list, detail };
