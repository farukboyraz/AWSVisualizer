import {
  OpenSearchClient,
  ListDomainNamesCommand,
  DescribeDomainsCommand,
  DescribeDomainCommand,
  ListTagsCommand,
  AddTagsCommand,
  RemoveTagsCommand,
} from '@aws-sdk/client-opensearch';
import {
  OpenSearchServerlessClient,
  ListCollectionsCommand,
  BatchGetCollectionCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-opensearchserverless';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, policyJson, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const domains = (p: string, r: string) => new OpenSearchClient({ region: r, credentials: cachedCredentials(p) });
const aoss = (p: string, r: string) => new OpenSearchServerlessClient({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const d = domains(profile, region);
  const [names, collections] = await Promise.all([
    d.send(new ListDomainNamesCommand({})).then((r) => r.DomainNames || []),
    pageAll((nextToken) => aoss(profile, region).send(new ListCollectionsCommand({ nextToken })), (r) => r.collectionSummaries, (r) => r.nextToken).catch(() => []),
  ]);
  const batches = Array.from({ length: Math.ceil(names.length / 5) }, (_, i) => names.slice(i * 5, i * 5 + 5).map((n) => n.DomainName || ''));
  const statuses = (await mapLimited(batches, 3, (DomainNames) => d.send(new DescribeDomainsCommand({ DomainNames })).then((r) => r.DomainStatusList || []))).flat();
  return [
    ...statuses
      .map((s) => ({
        id: `dom:${s.DomainName}`,
        name: s.DomainName || '',
        group: 'Domains',
        status: s.Deleted ? 'DELETING' : s.Processing ? 'PROCESSING' : 'ACTIVE',
        info: [s.EngineVersion, `${s.ClusterConfig?.InstanceCount ?? 0}× ${s.ClusterConfig?.InstanceType ?? ''}`, s.VPCOptions?.VPCId ? 'VPC' : 'public'].join(' · '),
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    ...collections.map((c) => ({ id: `coll:${c.id}`, name: c.name || c.id || '', group: 'Serverless collections', status: c.status })).sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function domainPage(profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const c = domains(profile, region);
  const s = (await c.send(new DescribeDomainCommand({ DomainName: name }))).DomainStatus;
  if (!s) throw httpError(`Domain not found: ${name}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsCommand({ ARN: s.ARN })) }, errors);
  const cc = s.ClusterConfig;
  const sec = s.AdvancedSecurityOptions;
  const endpoints = [s.Endpoint, s.EndpointV2, ...Object.values(s.Endpoints || {})].filter((x): x is string => Boolean(x));
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Domain', [
          ['Engine', s.EngineVersion],
          ['Status', s.Deleted ? 'Deleting' : s.Processing ? 'Processing a change' : 'Active'],
          ['Upgrade in progress', s.UpgradeProcessing],
          ['Service software', s.ServiceSoftwareOptions?.CurrentVersion],
          ['Update available', s.ServiceSoftwareOptions?.UpdateAvailable],
          ['IP address type', s.IPAddressType],
        ]),
        { title: 'Endpoints', settings: [], copyable: [...new Set(endpoints)].map((e) => ({ label: 'Endpoint', value: `https://${e}` })) },
        section('Cluster', [
          ['Data nodes', `${cc?.InstanceCount ?? 0} × ${cc?.InstanceType ?? '-'}`],
          ['Dedicated primary nodes', cc?.DedicatedMasterEnabled ? `${cc.DedicatedMasterCount} × ${cc.DedicatedMasterType}` : false],
          ['Zone awareness', cc?.ZoneAwarenessEnabled ? `${cc.ZoneAwarenessConfig?.AvailabilityZoneCount ?? 2} AZs` : false],
          ['Multi-AZ with standby', cc?.MultiAZWithStandbyEnabled],
          ['UltraWarm', cc?.WarmEnabled ? `${cc.WarmCount} × ${cc.WarmType}` : false],
          ['Cold storage', cc?.ColdStorageOptions?.Enabled],
          ['Storage', s.EBSOptions?.EBSEnabled ? `${s.EBSOptions.VolumeSize} GiB ${s.EBSOptions.VolumeType}${s.EBSOptions.Iops ? ` · ${s.EBSOptions.Iops} IOPS` : ''}` : 'Instance store'],
        ]),
        section('Network & security', [
          ['VPC', s.VPCOptions?.VPCId],
          ['Subnets', s.VPCOptions?.SubnetIds],
          ['Security groups', s.VPCOptions?.SecurityGroupIds],
          ['Fine-grained access control', sec?.Enabled],
          ['Internal user database', sec?.InternalUserDatabaseEnabled],
          ['SAML', sec?.SAMLOptions?.Enabled],
          ['Encryption at rest', s.EncryptionAtRestOptions?.Enabled],
          ['Node-to-node encryption', s.NodeToNodeEncryptionOptions?.Enabled],
          ['Require HTTPS', s.DomainEndpointOptions?.EnforceHTTPS],
          ['TLS policy', s.DomainEndpointOptions?.TLSSecurityPolicy],
          ['Custom endpoint', s.DomainEndpointOptions?.CustomEndpointEnabled ? s.DomainEndpointOptions.CustomEndpoint : undefined],
          ['Cognito (Dashboards)', s.CognitoOptions?.Enabled],
        ]),
      ].filter((x) => x.settings.length || ('copyable' in x && x.copyable?.length)),
      tables: [
        table(['Log', 'Enabled', 'Log group'], Object.entries(s.LogPublishingOptions || {}).map(([k, v]) => [k, v?.Enabled, v?.CloudWatchLogsLogGroupArn]), { title: 'Log publishing', emptyMessage: 'No logs published' }),
        table(['Option', 'Value'], Object.entries(s.AdvancedOptions || {}), { title: 'Advanced options', emptyMessage: 'Defaults' }),
      ],
    }),
  ];
  const policy = policyJson(s.AccessPolicies);
  if (policy) tabs.push(tab('Access policy', { json: policy }));
  return { id, title: name, subtitle: `OpenSearch domain · ${s.EngineVersion ?? ''}`, status: s.Processing ? 'PROCESSING' : 'ACTIVE', arn: s.ARN, tabs, tags: tagList(tags?.TagList), actions: [], errors };
}

async function collectionPage(profile: string, region: string, id: string, collectionId: string): Promise<ResourcePage> {
  const c = aoss(profile, region);
  const x = (await c.send(new BatchGetCollectionCommand({ ids: [collectionId] }))).collectionDetails?.[0];
  if (!x) throw httpError(`Collection not found: ${collectionId}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ resourceArn: x.arn })) }, errors);
  return {
    id,
    title: x.name || collectionId,
    subtitle: `Serverless ${x.type ?? ''} collection`,
    status: x.status,
    arn: x.arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Collection', [
            ['Type', x.type],
            ['Status', x.status],
            ['Description', x.description],
            ['Standby replicas', x.standbyReplicas],
            ['KMS key', x.kmsKeyArn],
            ['Failure', x.failureMessage],
            ['Created', x.createdDate ? new Date(x.createdDate) : undefined],
            ['Modified', x.lastModifiedDate ? new Date(x.lastModifiedDate) : undefined],
          ]),
          { title: 'Endpoints', settings: [], copyable: [x.collectionEndpoint && { label: 'Collection', value: x.collectionEndpoint }, x.dashboardEndpoint && { label: 'Dashboards', value: x.dashboardEndpoint }].filter((e): e is { label: string; value: string } => Boolean(e)) },
        ],
      }),
    ],
    tags: tagList(tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'dom') return domainPage(profile, region, id, rest);
  if (kind === 'coll') return collectionPage(profile, region, id, rest);
  throw httpError(`Unknown OpenSearch page: ${id}`, 400);
}

export const openSearchAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    if (id.startsWith('coll:')) await aoss(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ key, value }] }));
    else await domains(profile, region).send(new AddTagsCommand({ ARN: arn, TagList: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    if (id.startsWith('coll:')) await aoss(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
    else await domains(profile, region).send(new RemoveTagsCommand({ ARN: arn, TagKeys: [key] }));
  },
};
