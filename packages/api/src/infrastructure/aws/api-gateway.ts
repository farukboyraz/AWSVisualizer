import {
  APIGatewayClient,
  GetRestApisCommand,
  GetResourcesCommand,
  DeleteResourceCommand,
  DeleteMethodCommand,
  GetStagesCommand,
  CreateDeploymentCommand,
  DeleteStageCommand,
  UpdateRestApiCommand,
  DeleteRestApiCommand,
  type PatchOperation,
} from '@aws-sdk/client-api-gateway';
import { cachedCredentials } from './credential-cache.js';
import type { RestApi, ApiGatewayResource, ApiGatewayStage } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): APIGatewayClient {
  return new APIGatewayClient({ region, credentials: cachedCredentials(profile) });
}

export async function listRestApis(profile: string, region: string): Promise<RestApi[]> {
  const client = createClient(profile, region);
  const response = await client.send(new GetRestApisCommand({}));

  return (response.items || []).map((api) => ({
    id: api.id || '',
    name: api.name || '',
    description: api.description,
    createdDate: api.createdDate?.toISOString(),
    endpointType: api.endpointConfiguration?.types?.[0],
  }));
}

export async function getResources(profile: string, region: string, restApiId: string): Promise<ApiGatewayResource[]> {
  const client = createClient(profile, region);
  const resources: ApiGatewayResource[] = [];
  let position: string | undefined;

  do {
    const response = await client.send(new GetResourcesCommand({ restApiId, position, limit: 500 }));
    for (const r of response.items || []) {
      const methods = Object.entries(r.resourceMethods || {}).map(([httpMethod, method]) => ({
        httpMethod,
        authorizationType: method.authorizationType,
        apiKeyRequired: method.apiKeyRequired,
        integrationType: method.methodIntegration?.type,
        integrationUri: method.methodIntegration?.uri,
      }));
      resources.push({
        id: r.id || '',
        parentId: r.parentId,
        pathPart: r.pathPart,
        path: r.path || '/',
        methods,
      });
    }
    position = response.position;
  } while (position);

  return resources.sort((a, b) => a.path.localeCompare(b.path));
}

export async function deleteResource(profile: string, region: string, restApiId: string, resourceId: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteResourceCommand({ restApiId, resourceId }));
}

export async function deleteMethod(profile: string, region: string, restApiId: string, resourceId: string, httpMethod: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteMethodCommand({ restApiId, resourceId, httpMethod }));
}

export async function getStages(profile: string, region: string, restApiId: string): Promise<ApiGatewayStage[]> {
  const client = createClient(profile, region);
  const response = await client.send(new GetStagesCommand({ restApiId }));

  return (response.item || []).map((s) => ({
    stageName: s.stageName || '',
    deploymentId: s.deploymentId,
    description: s.description,
    lastUpdatedDate: s.lastUpdatedDate?.toISOString(),
    variables: Object.entries(s.variables || {}).map(([key, value]) => ({ key, value })),
  }));
}

export async function deployApi(
  profile: string,
  region: string,
  restApiId: string,
  stageName: string,
  description?: string
): Promise<ApiGatewayStage[]> {
  const client = createClient(profile, region);
  await client.send(new CreateDeploymentCommand({ restApiId, stageName, description }));
  return getStages(profile, region, restApiId);
}

export async function deleteStage(profile: string, region: string, restApiId: string, stageName: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteStageCommand({ restApiId, stageName }));
}

export async function updateRestApi(
  profile: string,
  region: string,
  restApiId: string,
  name?: string,
  description?: string
): Promise<RestApi | undefined> {
  const client = createClient(profile, region);
  const patchOperations: PatchOperation[] = [];
  if (name !== undefined) patchOperations.push({ op: 'replace', path: '/name', value: name });
  if (description !== undefined) patchOperations.push({ op: 'replace', path: '/description', value: description });

  if (patchOperations.length > 0) {
    await client.send(new UpdateRestApiCommand({ restApiId, patchOperations }));
  }

  const apis = await listRestApis(profile, region);
  return apis.find((a) => a.id === restApiId);
}

export async function deleteRestApi(profile: string, region: string, restApiId: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteRestApiCommand({ restApiId }));
}
