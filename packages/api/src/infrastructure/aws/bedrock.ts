import {
  BedrockClient,
  ListFoundationModelsCommand,
  GetModelInvocationLoggingConfigurationCommand,
  ListCustomModelsCommand,
  GetCustomModelCommand,
  ListProvisionedModelThroughputsCommand,
  GetProvisionedModelThroughputCommand,
  ListGuardrailsCommand,
  GetGuardrailCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-bedrock';
import {
  BedrockAgentClient,
  ListAgentsCommand,
  GetAgentCommand,
  ListAgentAliasesCommand,
  ListAgentActionGroupsCommand,
  ListAgentKnowledgeBasesCommand,
  ListKnowledgeBasesCommand,
  GetKnowledgeBaseCommand,
  ListDataSourcesCommand,
  ListTagsForResourceCommand as ListAgentTagsCommand,
  TagResourceCommand as TagAgentResourceCommand,
  UntagResourceCommand as UntagAgentResourceCommand,
} from '@aws-sdk/client-bedrock-agent';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, tagMap, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const bedrock = (p: string, r: string) => new BedrockClient({ region: r, credentials: cachedCredentials(p) });
const agents = (p: string, r: string) => new BedrockAgentClient({ region: r, credentials: cachedCredentials(p) });

/** Bedrock isn't in every region; there it answers with an endpoint / not-found error. */
const absent = (err: unknown) => ['UnknownEndpoint', 'ENOTFOUND', 'ResourceNotFoundException'].some((x) => `${(err as { name?: string; code?: string })?.name} ${(err as { code?: string })?.code}`.includes(x));

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const b = bedrock(profile, region);
  const a = agents(profile, region);
  let models;
  try {
    models = (await b.send(new ListFoundationModelsCommand({}))).modelSummaries || [];
  } catch (err) {
    if (absent(err)) return [];
    throw err;
  }
  const [custom, provisioned, guardrails, agentList, kbs] = await Promise.all([
    pageAll((nextToken) => b.send(new ListCustomModelsCommand({ nextToken })), (r) => r.modelSummaries, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => b.send(new ListProvisionedModelThroughputsCommand({ nextToken })), (r) => r.provisionedModelSummaries, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => b.send(new ListGuardrailsCommand({ nextToken })), (r) => r.guardrails, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => a.send(new ListAgentsCommand({ nextToken })), (r) => r.agentSummaries, (r) => r.nextToken).catch(() => []),
    pageAll((nextToken) => a.send(new ListKnowledgeBasesCommand({ nextToken })), (r) => r.knowledgeBaseSummaries, (r) => r.nextToken).catch(() => []),
  ]);
  const active = models.filter((m) => m.modelLifecycle?.status !== 'LEGACY').length;
  const byName = (x: PageSummary, y: PageSummary) => x.name.localeCompare(y.name);
  return [
    { id: 'fm:', name: 'Foundation models', group: 'Models', info: `${models.length} models (${active} active) · invocation logging` },
    ...custom.map((m) => ({ id: `cm:${m.modelArn}`, name: m.modelName || '', group: 'Custom models', info: [m.customizationType, m.baseModelName].filter(Boolean).join(' · ') })).sort(byName),
    ...provisioned.map((p) => ({ id: `pt:${p.provisionedModelArn}`, name: p.provisionedModelName || '', group: 'Provisioned throughput', status: p.status, info: `${p.modelUnits} model units · ${lastPart(p.foundationModelArn)}` })).sort(byName),
    ...guardrails.map((g) => ({ id: `gr:${g.id}`, name: g.name || '', group: 'Guardrails', status: g.status, info: `version ${g.version}` })).sort(byName),
    ...agentList.map((x) => ({ id: `agent:${x.agentId}`, name: x.agentName || '', group: 'Agents', status: x.agentStatus, info: x.description })).sort(byName),
    ...kbs.map((k) => ({ id: `kb:${k.knowledgeBaseId}`, name: k.name || '', group: 'Knowledge bases', status: k.status, info: k.description })).sort(byName),
  ];
}

async function foundationPage(c: BedrockClient): Promise<ResourcePage> {
  const errors: string[] = [];
  const parts = await settle({ models: c.send(new ListFoundationModelsCommand({})), logging: c.send(new GetModelInvocationLoggingConfigurationCommand({})) }, errors);
  // Active models first, then by provider and name; legacy ones at the end.
  const legacy = (m: { modelLifecycle?: { status?: string } }) => (m.modelLifecycle?.status === 'LEGACY' ? 1 : 0);
  const models = (parts.models?.modelSummaries || []).sort((a, b) => legacy(a) - legacy(b) || (a.providerName || '').localeCompare(b.providerName || '') || (a.modelName || '').localeCompare(b.modelName || ''));
  const log = parts.logging?.loggingConfig;
  return {
    id: 'fm:',
    title: 'Foundation models',
    subtitle: 'Models offered in this region',
    tabs: [
      tab('Models', {
        tables: [
          table(
            ['Provider', 'Model', 'Model ID', 'Input', 'Output', 'Streaming', 'Inference', 'Customization', 'Lifecycle'],
            models.map((m) => [m.providerName, m.modelName, m.modelId, m.inputModalities, m.outputModalities, m.responseStreamingSupported, m.inferenceTypesSupported, m.customizationsSupported, m.modelLifecycle?.status]),
            { statusColumn: 8, emptyMessage: 'No foundation models in this region' },
          ),
        ],
      }),
      tab('Invocation logging', {
        sections: [
          section('Model invocation logging', [
            ['Enabled', Boolean(log)],
            ['CloudWatch Logs', log?.cloudWatchConfig?.logGroupName],
            ['S3', log?.s3Config && `s3://${log.s3Config.bucketName}/${log.s3Config.keyPrefix ?? ''}`],
            ['Text data', log?.textDataDeliveryEnabled],
            ['Image data', log?.imageDataDeliveryEnabled],
            ['Embedding data', log?.embeddingDataDeliveryEnabled],
          ]),
        ],
      }),
    ],
    actions: [],
    errors,
  };
}

async function customPage(c: BedrockClient, id: string, arn: string): Promise<ResourcePage> {
  const m = await c.send(new GetCustomModelCommand({ modelIdentifier: arn }));
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ resourceARN: arn })) }, errors);
  return {
    id,
    title: m.modelName || arn,
    subtitle: `${m.customizationType ?? ''} custom model`,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Model', [
            ['Base model', m.baseModelArn],
            ['Customization', m.customizationType],
            ['Training job', lastPart(m.jobArn)],
            ['Training data', m.trainingDataConfig?.s3Uri],
            ['Validation data', (m.validationDataConfig?.validators || []).map((v) => v.s3Uri)],
            ['Output', m.outputDataConfig?.s3Uri],
            ['KMS key', m.modelKmsKeyArn],
            ['Created', m.creationTime],
          ]),
        ],
        tables: [
          table(['Hyperparameter', 'Value'], Object.entries(m.hyperParameters || {}), { title: 'Hyperparameters', emptyMessage: 'None' }),
          table(['Metric', 'Value'], Object.entries(m.trainingMetrics || {}), { title: 'Training metrics', emptyMessage: 'None' }),
        ],
      }),
    ],
    tags: tagList(tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))),
    actions: [],
    errors,
  };
}

async function provisionedPage(c: BedrockClient, id: string, arn: string): Promise<ResourcePage> {
  const p = await c.send(new GetProvisionedModelThroughputCommand({ provisionedModelId: arn }));
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ resourceARN: arn })) }, errors);
  return {
    id,
    title: p.provisionedModelName || arn,
    subtitle: 'Provisioned throughput',
    status: p.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Provisioned throughput', [
            ['Status', p.status],
            ['Failure', p.failureMessage],
            ['Model', p.modelArn],
            ['Foundation model', p.foundationModelArn],
            ['Model units', p.desiredModelUnits !== p.modelUnits ? `${p.modelUnits} (changing to ${p.desiredModelUnits})` : p.modelUnits],
            ['Commitment', p.commitmentDuration ?? 'No commitment (hourly)'],
            ['Commitment ends', p.commitmentExpirationTime],
            ['Created', p.creationTime],
            ['Modified', p.lastModifiedTime],
          ]),
        ],
      }),
    ],
    tags: tagList(tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))),
    actions: [],
    errors,
  };
}

async function guardrailPage(c: BedrockClient, id: string, guardrailId: string): Promise<ResourcePage> {
  const g = await c.send(new GetGuardrailCommand({ guardrailIdentifier: guardrailId }));
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ resourceARN: g.guardrailArn })) }, errors);
  const pii = g.sensitiveInformationPolicy;
  return {
    id,
    title: g.name || guardrailId,
    subtitle: `Guardrail · version ${g.version}`,
    status: g.status,
    arn: g.guardrailArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Guardrail', [
            ['Status', g.status],
            ['Status reasons', g.statusReasons],
            ['Description', g.description],
            ['Blocked input message', g.blockedInputMessaging],
            ['Blocked output message', g.blockedOutputsMessaging],
            ['KMS key', g.kmsKeyArn],
            ['Created', g.createdAt],
            ['Updated', g.updatedAt],
          ]),
          section('Word filters', [['Custom words', g.wordPolicy?.words?.length], ['Managed lists', (g.wordPolicy?.managedWordLists || []).map((w) => w.type)]]),
          section('Contextual grounding', [['Checks', (g.contextualGroundingPolicy?.filters || []).map((f) => `${f.type} ≥ ${f.threshold}`)]]),
        ],
        tables: [
          table(['Content filter', 'Input', 'Output'], (g.contentPolicy?.filters || []).map((f) => [f.type, f.inputStrength, f.outputStrength]), { title: 'Content filters', emptyMessage: 'No content filters' }),
          table(['Denied topic', 'Definition', 'Examples'], (g.topicPolicy?.topics || []).map((t) => [t.name, t.definition, t.examples?.length]), { title: 'Denied topics', emptyMessage: 'No denied topics' }),
          table(['Sensitive information', 'Action'], [...(pii?.piiEntities || []).map((p) => [p.type, p.action]), ...(pii?.regexes || []).map((r) => [`Regex: ${r.name}`, r.action])], { title: 'Sensitive information filters', emptyMessage: 'None' }),
        ],
      }),
    ],
    tags: tagList(tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))),
    actions: [],
    errors,
  };
}

async function agentPage(c: BedrockAgentClient, id: string, agentId: string): Promise<ResourcePage> {
  const x = (await c.send(new GetAgentCommand({ agentId }))).agent;
  if (!x) throw httpError(`Agent not found: ${agentId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      aliases: pageAll((nextToken) => c.send(new ListAgentAliasesCommand({ agentId, nextToken })), (r) => r.agentAliasSummaries, (r) => r.nextToken),
      actions: pageAll((nextToken) => c.send(new ListAgentActionGroupsCommand({ agentId, agentVersion: 'DRAFT', nextToken })), (r) => r.actionGroupSummaries, (r) => r.nextToken),
      kbs: pageAll((nextToken) => c.send(new ListAgentKnowledgeBasesCommand({ agentId, agentVersion: 'DRAFT', nextToken })), (r) => r.agentKnowledgeBaseSummaries, (r) => r.nextToken),
      tags: c.send(new ListAgentTagsCommand({ resourceArn: x.agentArn })),
    },
    errors,
  );
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Agent', [
          ['Status', x.agentStatus],
          ['Failure', x.failureReasons],
          ['Foundation model', x.foundationModel],
          ['Description', x.description],
          ['Idle session timeout (s)', x.idleSessionTTLInSeconds],
          ['Guardrail', x.guardrailConfiguration?.guardrailIdentifier && `${x.guardrailConfiguration.guardrailIdentifier} v${x.guardrailConfiguration.guardrailVersion}`],
          ['Memory', x.memoryConfiguration?.enabledMemoryTypes],
          ['Service role', x.agentResourceRoleArn],
          ['KMS key', x.customerEncryptionKeyArn],
          ['Prepared', x.preparedAt],
          ['Created', x.createdAt],
          ['Updated', x.updatedAt],
        ]),
      ],
      tables: [
        table(['Alias', 'Status', 'Routes to version', 'Updated'], (parts.aliases || []).map((a) => [a.agentAliasName, a.agentAliasStatus, (a.routingConfiguration || []).map((r) => r.agentVersion), a.updatedAt]), { title: 'Aliases', statusColumn: 1, emptyMessage: 'No aliases' }),
        table(['Action group', 'State', 'Description'], (parts.actions || []).map((a) => [a.actionGroupName, a.actionGroupState, a.description]), { title: 'Action groups (draft)', statusColumn: 1, emptyMessage: 'No action groups' }),
        table(['Knowledge base', 'State', 'Description'], (parts.kbs || []).map((k) => [k.knowledgeBaseId, k.knowledgeBaseState, k.description]), { title: 'Knowledge bases (draft)', statusColumn: 1, emptyMessage: 'No knowledge bases' }),
      ],
    }),
  ];
  if (x.instruction) tabs.push(tab('Instructions', { text: x.instruction }));
  return { id, title: x.agentName || agentId, subtitle: 'Bedrock agent', status: x.agentStatus, arn: x.agentArn, tabs, tags: tagMap(parts.tags?.tags), actions: [], errors };
}

async function knowledgeBasePage(c: BedrockAgentClient, id: string, kbId: string): Promise<ResourcePage> {
  const k = (await c.send(new GetKnowledgeBaseCommand({ knowledgeBaseId: kbId }))).knowledgeBase;
  if (!k) throw httpError(`Knowledge base not found: ${kbId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      sources: pageAll((nextToken) => c.send(new ListDataSourcesCommand({ knowledgeBaseId: kbId, nextToken })), (r) => r.dataSourceSummaries, (r) => r.nextToken),
      tags: c.send(new ListAgentTagsCommand({ resourceArn: k.knowledgeBaseArn })),
    },
    errors,
  );
  const st = k.storageConfiguration;
  // Vector store connection: only the store type and its endpoint / index - credentials stay in Secrets Manager (ARN only).
  const store = st?.opensearchServerlessConfiguration
    ? ['OpenSearch Serverless', st.opensearchServerlessConfiguration.collectionArn, st.opensearchServerlessConfiguration.vectorIndexName]
    : st?.pineconeConfiguration
      ? ['Pinecone', st.pineconeConfiguration.connectionString, st.pineconeConfiguration.namespace]
      : st?.rdsConfiguration
        ? ['Aurora PostgreSQL', st.rdsConfiguration.resourceArn, st.rdsConfiguration.tableName]
        : st?.redisEnterpriseCloudConfiguration
          ? ['Redis Enterprise Cloud', st.redisEnterpriseCloudConfiguration.endpoint, st.redisEnterpriseCloudConfiguration.vectorIndexName]
          : st?.mongoDbAtlasConfiguration
            ? ['MongoDB Atlas', st.mongoDbAtlasConfiguration.endpoint, st.mongoDbAtlasConfiguration.collectionName]
            : [st?.type, undefined, undefined];
  return {
    id,
    title: k.name || kbId,
    subtitle: 'Knowledge base',
    status: k.status,
    arn: k.knowledgeBaseArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Knowledge base', [
            ['Status', k.status],
            ['Failure', k.failureReasons],
            ['Description', k.description],
            ['Type', k.knowledgeBaseConfiguration?.type],
            ['Embedding model', k.knowledgeBaseConfiguration?.vectorKnowledgeBaseConfiguration?.embeddingModelArn],
            ['Vector store', store[0]],
            ['Store location', store[1]],
            ['Index / table', store[2]],
            ['Role', k.roleArn],
            ['Created', k.createdAt],
            ['Updated', k.updatedAt],
          ]),
        ],
        tables: [table(['Data source', 'Status', 'Updated', 'Description'], (parts.sources || []).map((s) => [s.name, s.status, s.updatedAt, s.description]), { title: 'Data sources', statusColumn: 1, emptyMessage: 'No data sources' })],
      }),
    ],
    tags: tagMap(parts.tags?.tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'fm') return foundationPage(bedrock(profile, region));
  if (kind === 'cm') return customPage(bedrock(profile, region), id, rest);
  if (kind === 'pt') return provisionedPage(bedrock(profile, region), id, rest);
  if (kind === 'gr') return guardrailPage(bedrock(profile, region), id, rest);
  if (kind === 'agent') return agentPage(agents(profile, region), id, rest);
  if (kind === 'kb') return knowledgeBasePage(agents(profile, region), id, rest);
  throw httpError(`Unknown Bedrock page: ${id}`, 400);
}

export const bedrockAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    const [kind] = splitId(id);
    if (!arn || kind === 'fm') throw httpError('This page has no tags', 400);
    if (kind === 'agent' || kind === 'kb') await agents(profile, region).send(new TagAgentResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
    else await bedrock(profile, region).send(new TagResourceCommand({ resourceARN: arn, tags: [{ key, value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    const [kind] = splitId(id);
    if (!arn || kind === 'fm') throw httpError('This page has no tags', 400);
    if (kind === 'agent' || kind === 'kb') await agents(profile, region).send(new UntagAgentResourceCommand({ resourceArn: arn, tagKeys: [key] }));
    else await bedrock(profile, region).send(new UntagResourceCommand({ resourceARN: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id !== 'fm:',
};
