import {
  ApiGatewayV2Client,
  GetApisCommand,
  GetApiCommand,
  GetRoutesCommand,
  GetIntegrationsCommand,
  GetStagesCommand,
  GetAuthorizersCommand,
  CreateDeploymentCommand,
  DeleteApiCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Integration,
} from '@aws-sdk/client-apigatewayv2';
import { cachedCredentials } from './credential-cache.js';
import type {
  HttpApi,
  HttpApiDetail,
  HttpApiRoute,
  HttpApiIntegration,
  HttpApiStage,
  HttpApiAuthorizer,
} from '../../domain/entities/index.js';

// API Gateway v2 covers HTTP APIs and WebSocket APIs. REST APIs (v1) stay in
// api-gateway.ts - the two are separate AWS APIs with different models
// (v1: resources + methods; v2: routes "METHOD /path" + integrations).

function createClient(profile: string, region: string): ApiGatewayV2Client {
  return new ApiGatewayV2Client({ region, credentials: cachedCredentials(profile) });
}

/** v2 list calls page with NextToken (string page size). */
async function collect<T>(fetchPage: (nextToken?: string) => Promise<{ Items?: T[]; NextToken?: string }>): Promise<T[]> {
  const items: T[] = [];
  let nextToken: string | undefined;
  do {
    const page = await fetchPage(nextToken);
    items.push(...(page.Items || []));
    nextToken = page.NextToken;
  } while (nextToken);
  return items;
}

export async function listHttpApis(profile: string, region: string): Promise<HttpApi[]> {
  const client = createClient(profile, region);
  const apis = await collect((NextToken) => client.send(new GetApisCommand({ NextToken, MaxResults: '500' })));
  return apis
    .map((a) => ({
      apiId: a.ApiId || '',
      name: a.Name || '',
      protocolType: a.ProtocolType || 'HTTP',
      apiEndpoint: a.ApiEndpoint,
      description: a.Description,
      createdDate: a.CreatedDate?.toISOString(),
    }))
    .sort((x, y) => x.name.localeCompare(y.name));
}

function integrationTarget(i: Integration): string | undefined {
  // Lambda proxy: the function ARN (or invoke URI); HTTP proxy: the URL;
  // AWS service integrations: the subtype (e.g. SQS-SendMessage).
  return i.IntegrationUri || i.IntegrationSubtype || undefined;
}

export async function getHttpApiDetail(profile: string, region: string, apiId: string): Promise<HttpApiDetail> {
  const client = createClient(profile, region);
  const [api, routes, integrations, stages, authorizers] = await Promise.all([
    client.send(new GetApiCommand({ ApiId: apiId })),
    collect((NextToken) => client.send(new GetRoutesCommand({ ApiId: apiId, NextToken, MaxResults: '500' }))),
    collect((NextToken) => client.send(new GetIntegrationsCommand({ ApiId: apiId, NextToken, MaxResults: '500' }))),
    collect((NextToken) => client.send(new GetStagesCommand({ ApiId: apiId, NextToken, MaxResults: '500' }))),
    collect((NextToken) => client.send(new GetAuthorizersCommand({ ApiId: apiId, NextToken, MaxResults: '500' }))),
  ]);

  const mappedIntegrations: HttpApiIntegration[] = integrations.map((i) => ({
    integrationId: i.IntegrationId || '',
    integrationType: i.IntegrationType || '',
    integrationMethod: i.IntegrationMethod,
    target: integrationTarget(i),
    connectionType: i.ConnectionType,
    payloadFormatVersion: i.PayloadFormatVersion,
    timeoutInMillis: i.TimeoutInMillis,
    description: i.Description,
  }));

  const mappedRoutes: HttpApiRoute[] = routes
    .map((r) => {
      // Route target is "integrations/<id>" when attached.
      const integrationId = r.Target?.startsWith('integrations/') ? r.Target.slice('integrations/'.length) : undefined;
      return {
        routeId: r.RouteId || '',
        routeKey: r.RouteKey || '',
        authorizationType: r.AuthorizationType,
        authorizerId: r.AuthorizerId,
        authorizationScopes: r.AuthorizationScopes || [],
        integrationId,
        apiKeyRequired: r.ApiKeyRequired,
      };
    })
    .sort((a, b) => routeSortKey(a.routeKey).localeCompare(routeSortKey(b.routeKey)));

  const mappedStages: HttpApiStage[] = stages
    .map((s) => ({
      stageName: s.StageName || '',
      autoDeploy: s.AutoDeploy ?? false,
      deploymentId: s.DeploymentId,
      description: s.Description,
      createdDate: s.CreatedDate?.toISOString(),
      lastUpdatedDate: s.LastUpdatedDate?.toISOString(),
      lastDeploymentStatusMessage: s.LastDeploymentStatusMessage,
      throttlingBurstLimit: s.DefaultRouteSettings?.ThrottlingBurstLimit,
      throttlingRateLimit: s.DefaultRouteSettings?.ThrottlingRateLimit,
      detailedMetricsEnabled: s.DefaultRouteSettings?.DetailedMetricsEnabled,
      accessLogDestination: s.AccessLogSettings?.DestinationArn,
      stageVariables: Object.entries(s.StageVariables || {}).map(([key, value]) => ({ key, value: value || '' })),
      invokeUrl: stageInvokeUrl(api.ApiEndpoint, s.StageName),
    }))
    .sort((a, b) => (a.stageName === '$default' ? -1 : b.stageName === '$default' ? 1 : a.stageName.localeCompare(b.stageName)));

  const mappedAuthorizers: HttpApiAuthorizer[] = authorizers.map((a) => ({
    authorizerId: a.AuthorizerId || '',
    name: a.Name || '',
    authorizerType: a.AuthorizerType || '',
    identitySource: a.IdentitySource || [],
    issuer: a.JwtConfiguration?.Issuer,
    audience: a.JwtConfiguration?.Audience || [],
    authorizerUri: a.AuthorizerUri,
    payloadFormatVersion: a.AuthorizerPayloadFormatVersion,
    enableSimpleResponses: a.EnableSimpleResponses,
    resultTtlInSeconds: a.AuthorizerResultTtlInSeconds,
  }));

  const cors = api.CorsConfiguration;
  return {
    apiId: api.ApiId || apiId,
    name: api.Name || '',
    protocolType: api.ProtocolType || 'HTTP',
    apiEndpoint: api.ApiEndpoint,
    description: api.Description,
    createdDate: api.CreatedDate?.toISOString(),
    disableExecuteApiEndpoint: api.DisableExecuteApiEndpoint ?? false,
    routeSelectionExpression: api.RouteSelectionExpression,
    apiKeySelectionExpression: api.ApiKeySelectionExpression,
    version: api.Version,
    arn: `arn:aws:apigateway:${region}::/apis/${api.ApiId || apiId}`,
    cors: cors
      ? {
          allowOrigins: cors.AllowOrigins || [],
          allowMethods: cors.AllowMethods || [],
          allowHeaders: cors.AllowHeaders || [],
          exposeHeaders: cors.ExposeHeaders || [],
          allowCredentials: cors.AllowCredentials ?? false,
          maxAge: cors.MaxAge,
        }
      : undefined,
    tags: Object.entries(api.Tags || {}).map(([key, value]) => ({ key, value: value || '' })),
    routes: mappedRoutes,
    integrations: mappedIntegrations,
    stages: mappedStages,
    authorizers: mappedAuthorizers,
  };
}

/** "$default" stage is served at the bare endpoint, others at /<stage>. */
export function stageInvokeUrl(endpoint: string | undefined, stageName: string | undefined): string | undefined {
  if (!endpoint || !stageName) return undefined;
  return stageName === '$default' ? endpoint : `${endpoint}/${stageName}`;
}

/** Sort routes by path, then method, keeping "$default" last. */
function routeSortKey(routeKey: string): string {
  if (routeKey === '$default') return '￿';
  const [method, path] = routeKey.includes(' ') ? routeKey.split(' ', 2) : ['', routeKey];
  return `${path} ${method}`;
}

/** For stages without auto-deploy - the console's "Deploy" button. */
export async function deployHttpApi(profile: string, region: string, apiId: string, stageName: string, description?: string): Promise<HttpApiDetail> {
  const client = createClient(profile, region);
  await client.send(new CreateDeploymentCommand({ ApiId: apiId, StageName: stageName, Description: description || undefined }));
  return getHttpApiDetail(profile, region, apiId);
}

export async function deleteHttpApi(profile: string, region: string, apiId: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteApiCommand({ ApiId: apiId }));
}

export async function addHttpApiTag(profile: string, region: string, apiId: string, key: string, value: string): Promise<HttpApiDetail> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ ResourceArn: `arn:aws:apigateway:${region}::/apis/${apiId}`, Tags: { [key]: value } }));
  return getHttpApiDetail(profile, region, apiId);
}

export async function removeHttpApiTag(profile: string, region: string, apiId: string, key: string): Promise<HttpApiDetail> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ ResourceArn: `arn:aws:apigateway:${region}::/apis/${apiId}`, TagKeys: [key] }));
  return getHttpApiDetail(profile, region, apiId);
}
