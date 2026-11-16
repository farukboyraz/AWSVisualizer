import {
  AppSyncClient,
  ListGraphqlApisCommand,
  GetGraphqlApiCommand,
  ListDataSourcesCommand,
  ListApiKeysCommand,
  ListTypesCommand,
  ListResolversCommand,
  ListFunctionsCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-appsync';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/**
 * AppSync: GraphQL APIs with data sources, resolvers and functions.
 * API keys are shown only as a count with expiry dates - the key's id IS
 * the secret, so it is never output.
 */
const client = (p: string, r: string) => new AppSyncClient(clientConfig(p, r));

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const apis = await pageAll((nextToken) => client(profile, region).send(new ListGraphqlApisCommand({ nextToken })), (r) => r.graphqlApis, (r) => r.nextToken);
  return apis.map((a) => ({ id: `api:${a.apiId}`, name: a.name || a.apiId || '', info: [a.authenticationType, a.apiType, a.visibility].filter(Boolean).join(' · ') })).sort(byName);
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, apiId] = splitId(id);
  if (kind !== 'api') throw httpError(`Unknown AppSync page: ${id}`, 400);
  const c = client(profile, region);
  const a = (await c.send(new GetGraphqlApiCommand({ apiId }))).graphqlApi;
  if (!a) throw httpError(`API not found: ${apiId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      sources: pageAll((nextToken) => c.send(new ListDataSourcesCommand({ apiId, nextToken })), (r) => r.dataSources, (r) => r.nextToken),
      keys: pageAll((nextToken) => c.send(new ListApiKeysCommand({ apiId, nextToken })), (r) => r.apiKeys, (r) => r.nextToken),
      types: pageAll((nextToken) => c.send(new ListTypesCommand({ apiId, format: 'SDL', nextToken })), (r) => r.types, (r) => r.nextToken),
      functions: pageAll((nextToken) => c.send(new ListFunctionsCommand({ apiId, nextToken })), (r) => r.functions, (r) => r.nextToken),
    },
    errors,
  );
  // Resolvers of the root types (Query / Mutation / Subscription).
  const roots = (parts.types || []).filter((t) => ['Query', 'Mutation', 'Subscription'].includes(t.name || ''));
  const resolvers = (await Promise.all(roots.map((t) => pageAll((nextToken) => c.send(new ListResolversCommand({ apiId, typeName: t.name, nextToken })), (r) => r.resolvers, (r) => r.nextToken).catch(() => [])))).flat();
  const target = (d: NonNullable<typeof parts.sources>[number]) => d.dynamodbConfig?.tableName ?? lastPart(d.lambdaConfig?.lambdaFunctionArn) ?? d.httpConfig?.endpoint ?? d.openSearchServiceConfig?.endpoint ?? d.relationalDatabaseConfig?.rdsHttpEndpointConfig?.databaseName ?? lastPart(d.eventBridgeConfig?.eventBusArn);
  const now = Date.now() / 1000;
  return {
    id,
    title: a.name || apiId,
    subtitle: `GraphQL API · ${a.authenticationType ?? ''}`,
    arn: a.arn,
    tabs: [
      tab('Details', {
        sections: [
          section('API', [
            ['API ID', a.apiId],
            ['Type', a.apiType],
            ['Visibility', a.visibility],
            ['Authentication', [a.authenticationType, ...(a.additionalAuthenticationProviders || []).map((p) => p.authenticationType)]],
            ['Cognito user pool', a.userPoolConfig?.userPoolId],
            ['OIDC issuer', a.openIDConnectConfig?.issuer],
            ['Logging', a.logConfig?.fieldLogLevel],
            ['X-Ray', a.xrayEnabled],
            ['WAF web ACL', lastPart(a.wafWebAclArn)],
            ['API keys', parts.keys ? `${parts.keys.length} (${parts.keys.filter((k) => (k.expires ?? 0) < now).length} expired)` : undefined],
            ['Next key expiry', parts.keys?.length ? new Date(Math.min(...parts.keys.map((k) => k.expires ?? Infinity)) * 1000) : undefined],
          ]),
          { title: 'Endpoints', settings: [], copyable: Object.entries(a.uris || {}).map(([k, v]) => ({ label: k, value: v })) },
        ],
      }),
      tab('Data sources', {
        tables: [table(['Data source', 'Type', 'Target', 'Role'], (parts.sources || []).map((d) => [d.name, d.type, target(d), lastPart(d.serviceRoleArn)]), { emptyMessage: 'No data sources' })],
      }),
      tab('Resolvers', {
        tables: [
          table(['Type', 'Field', 'Kind', 'Data source', 'Runtime', 'Caching'], resolvers.map((r) => [r.typeName, r.fieldName, r.kind, r.dataSourceName ?? (r.pipelineConfig?.functions?.length ? `${r.pipelineConfig.functions.length} functions` : undefined), r.runtime?.name, r.cachingConfig ? `${r.cachingConfig.ttl} s` : undefined]), { title: 'Query / Mutation / Subscription resolvers', emptyMessage: 'No resolvers' }),
          table(['Function', 'Data source', 'Runtime'], (parts.functions || []).map((f) => [f.name, f.dataSourceName, f.runtime?.name]), { title: 'Pipeline functions', emptyMessage: 'No functions' }),
        ],
      }),
    ],
    tags: tagMap(a.tags),
    actions: [],
    errors,
  };
}

export const appSyncAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
};
