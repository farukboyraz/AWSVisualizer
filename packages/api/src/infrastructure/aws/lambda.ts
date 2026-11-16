import {
  LambdaClient,
  ListFunctionsCommand,
  GetFunctionCommand,
  UpdateFunctionConfigurationCommand,
  InvokeCommand,
  ListVersionsByFunctionCommand,
  PublishVersionCommand,
  ListAliasesCommand,
  CreateAliasCommand,
  UpdateAliasCommand,
  DeleteAliasCommand,
  ListEventSourceMappingsCommand,
  CreateEventSourceMappingCommand,
  UpdateEventSourceMappingCommand,
  DeleteEventSourceMappingCommand,
  GetFunctionConcurrencyCommand,
  PutFunctionConcurrencyCommand,
  DeleteFunctionConcurrencyCommand,
  TagResourceCommand,
  UntagResourceCommand,
  DeleteFunctionCommand,
  CreateFunctionCommand,
  type Runtime,
} from '@aws-sdk/client-lambda';
import { CloudWatchClient, GetMetricStatisticsCommand } from '@aws-sdk/client-cloudwatch';
import { cachedCredentials } from './credential-cache.js';
import JSZip from 'jszip';
import { promises as fsPromises } from 'fs';
import { join, dirname, resolve, sep } from 'path';
import { tmpdir } from 'os';
import type {
  LambdaFunction,
  LambdaFunctionDetail,
  LambdaVersion,
  LambdaAlias,
  LambdaEventSourceMapping,
  LambdaInvokeResult,
  LambdaMetricsSummary,
  ZipEntry,
  ZipEntryContent,
} from '../../domain/entities/index.js';

function createLambdaClient(profile: string, region: string): LambdaClient {
  return new LambdaClient({ region, credentials: cachedCredentials(profile) });
}

function createCloudWatchClient(profile: string, region: string): CloudWatchClient {
  return new CloudWatchClient({ region, credentials: cachedCredentials(profile) });
}

export async function listFunctions(profile: string, region: string): Promise<LambdaFunction[]> {
  const client = createLambdaClient(profile, region);
  const command = new ListFunctionsCommand({});
  const response = await client.send(command);

  return (response.Functions || []).map((fn) => ({
    functionName: fn.FunctionName || '',
    runtime: fn.Runtime || '',
    handler: fn.Handler || '',
    codeSize: fn.CodeSize || 0,
    memorySize: fn.MemorySize || 0,
    timeout: fn.Timeout || 0,
    lastModified: fn.LastModified || '',
    state: fn.State,
    description: fn.Description,
  }));
}

export async function getFunctionDetail(profile: string, region: string, functionName: string): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  const [functionRes, concurrencyRes] = await Promise.all([
    client.send(new GetFunctionCommand({ FunctionName: functionName })),
    client.send(new GetFunctionConcurrencyCommand({ FunctionName: functionName })).catch(() => undefined),
  ]);

  const config = functionRes.Configuration || {};
  const tags = functionRes.Tags || {};

  return {
    functionName: config.FunctionName || functionName,
    functionArn: config.FunctionArn || '',
    runtime: config.Runtime,
    handler: config.Handler,
    role: config.Role,
    codeSize: config.CodeSize || 0,
    memorySize: config.MemorySize || 0,
    timeout: config.Timeout || 0,
    lastModified: config.LastModified || '',
    description: config.Description,
    state: config.State,
    stateReason: config.StateReason,
    architectures: config.Architectures,
    packageType: config.PackageType,
    environmentVariables: config.Environment?.Variables || {},
    reservedConcurrentExecutions: concurrencyRes?.ReservedConcurrentExecutions,
    tags: Object.entries(tags).map(([key, value]) => ({ key, value: value || '' })),
    codeLocation: functionRes.Code?.Location,
  };
}

/**
 * Last-24h summary for the Monitor tab - a single `GetMetricStatistics`
 * call per metric with `Period` set to the whole window so each comes back
 * as one datapoint, rather than pulling a full time series and charting it
 * (the console's Monitor tab does that; this app deliberately doesn't take
 * on a charting dependency for one metrics tab).
 */
export async function getFunctionMetrics(profile: string, region: string, functionName: string): Promise<LambdaMetricsSummary> {
  const client = createCloudWatchClient(profile, region);
  const endTime = new Date();
  const startTime = new Date(endTime.getTime() - 24 * 60 * 60 * 1000);
  const dimensions = [{ Name: 'FunctionName', Value: functionName }];
  const periodSeconds = 24 * 60 * 60;

  const [invocations, errors, throttles, duration] = await Promise.all([
    client.send(new GetMetricStatisticsCommand({ Namespace: 'AWS/Lambda', MetricName: 'Invocations', Dimensions: dimensions, StartTime: startTime, EndTime: endTime, Period: periodSeconds, Statistics: ['Sum'] })),
    client.send(new GetMetricStatisticsCommand({ Namespace: 'AWS/Lambda', MetricName: 'Errors', Dimensions: dimensions, StartTime: startTime, EndTime: endTime, Period: periodSeconds, Statistics: ['Sum'] })),
    client.send(new GetMetricStatisticsCommand({ Namespace: 'AWS/Lambda', MetricName: 'Throttles', Dimensions: dimensions, StartTime: startTime, EndTime: endTime, Period: periodSeconds, Statistics: ['Sum'] })),
    client.send(new GetMetricStatisticsCommand({ Namespace: 'AWS/Lambda', MetricName: 'Duration', Dimensions: dimensions, StartTime: startTime, EndTime: endTime, Period: periodSeconds, Statistics: ['Average'] })),
  ]);

  return {
    invocations: invocations.Datapoints?.[0]?.Sum || 0,
    errors: errors.Datapoints?.[0]?.Sum || 0,
    throttles: throttles.Datapoints?.[0]?.Sum || 0,
    averageDurationMs: duration.Datapoints?.[0]?.Average || 0,
    logGroupName: `/aws/lambda/${functionName}`,
  };
}

export async function updateFunctionConfig(
  profile: string,
  region: string,
  functionName: string,
  updates: { memorySize?: number; timeout?: number; description?: string }
): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  await client.send(new UpdateFunctionConfigurationCommand({
    FunctionName: functionName,
    MemorySize: updates.memorySize,
    Timeout: updates.timeout,
    Description: updates.description,
  }));
  return getFunctionDetail(profile, region, functionName);
}

export async function updateEnvironmentVariables(
  profile: string,
  region: string,
  functionName: string,
  variables: Record<string, string>
): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  await client.send(new UpdateFunctionConfigurationCommand({
    FunctionName: functionName,
    Environment: { Variables: variables },
  }));
  return getFunctionDetail(profile, region, functionName);
}

export async function invokeFunction(profile: string, region: string, functionName: string, payload: string): Promise<LambdaInvokeResult> {
  const client = createLambdaClient(profile, region);
  const response = await client.send(new InvokeCommand({
    FunctionName: functionName,
    Payload: Buffer.from(payload || '{}'),
    LogType: 'Tail',
  }));

  return {
    statusCode: response.StatusCode,
    payload: response.Payload ? Buffer.from(response.Payload).toString('utf-8') : undefined,
    logResult: response.LogResult ? Buffer.from(response.LogResult, 'base64').toString('utf-8') : undefined,
    functionError: response.FunctionError,
    executedVersion: response.ExecutedVersion,
  };
}

export async function listVersions(profile: string, region: string, functionName: string): Promise<LambdaVersion[]> {
  const client = createLambdaClient(profile, region);
  const response = await client.send(new ListVersionsByFunctionCommand({ FunctionName: functionName }));
  return (response.Versions || [])
    .filter((v) => v.Version !== '$LATEST')
    .map((v) => ({
      version: v.Version || '',
      lastModified: v.LastModified || '',
      description: v.Description,
      codeSize: v.CodeSize || 0,
    }))
    .reverse();
}

export async function publishVersion(profile: string, region: string, functionName: string, description?: string): Promise<LambdaVersion> {
  const client = createLambdaClient(profile, region);
  const response = await client.send(new PublishVersionCommand({ FunctionName: functionName, Description: description }));
  return {
    version: response.Version || '',
    lastModified: response.LastModified || '',
    description: response.Description,
    codeSize: response.CodeSize || 0,
  };
}

export async function listAliases(profile: string, region: string, functionName: string): Promise<LambdaAlias[]> {
  const client = createLambdaClient(profile, region);
  const response = await client.send(new ListAliasesCommand({ FunctionName: functionName }));
  return (response.Aliases || []).map((a) => ({
    name: a.Name || '',
    functionVersion: a.FunctionVersion || '',
    description: a.Description,
    aliasArn: a.AliasArn || '',
  }));
}

export async function createAlias(profile: string, region: string, functionName: string, name: string, functionVersion: string, description?: string): Promise<LambdaAlias[]> {
  const client = createLambdaClient(profile, region);
  await client.send(new CreateAliasCommand({ FunctionName: functionName, Name: name, FunctionVersion: functionVersion, Description: description }));
  return listAliases(profile, region, functionName);
}

export async function updateAlias(profile: string, region: string, functionName: string, name: string, functionVersion: string, description?: string): Promise<LambdaAlias[]> {
  const client = createLambdaClient(profile, region);
  await client.send(new UpdateAliasCommand({ FunctionName: functionName, Name: name, FunctionVersion: functionVersion, Description: description }));
  return listAliases(profile, region, functionName);
}

export async function deleteAlias(profile: string, region: string, functionName: string, name: string): Promise<LambdaAlias[]> {
  const client = createLambdaClient(profile, region);
  await client.send(new DeleteAliasCommand({ FunctionName: functionName, Name: name }));
  return listAliases(profile, region, functionName);
}

export async function listEventSourceMappings(profile: string, region: string, functionName: string): Promise<LambdaEventSourceMapping[]> {
  const client = createLambdaClient(profile, region);
  const response = await client.send(new ListEventSourceMappingsCommand({ FunctionName: functionName }));
  return (response.EventSourceMappings || []).map((m) => ({
    uuid: m.UUID || '',
    eventSourceArn: m.EventSourceArn,
    functionArn: m.FunctionArn,
    state: m.State,
    batchSize: m.BatchSize,
    lastModified: m.LastModified?.toISOString(),
    startingPosition: undefined,
  }));
}

export async function createEventSourceMapping(
  profile: string,
  region: string,
  functionName: string,
  eventSourceArn: string,
  batchSize: number | undefined,
  startingPosition: 'TRIM_HORIZON' | 'LATEST' | undefined
): Promise<LambdaEventSourceMapping[]> {
  const client = createLambdaClient(profile, region);
  await client.send(new CreateEventSourceMappingCommand({
    FunctionName: functionName,
    EventSourceArn: eventSourceArn,
    BatchSize: batchSize,
    StartingPosition: startingPosition,
    Enabled: true,
  }));
  return listEventSourceMappings(profile, region, functionName);
}

export async function setEventSourceMappingEnabled(profile: string, region: string, functionName: string, uuid: string, enabled: boolean): Promise<LambdaEventSourceMapping[]> {
  const client = createLambdaClient(profile, region);
  await client.send(new UpdateEventSourceMappingCommand({ UUID: uuid, Enabled: enabled }));
  return listEventSourceMappings(profile, region, functionName);
}

export async function deleteEventSourceMapping(profile: string, region: string, functionName: string, uuid: string): Promise<LambdaEventSourceMapping[]> {
  const client = createLambdaClient(profile, region);
  await client.send(new DeleteEventSourceMappingCommand({ UUID: uuid }));
  return listEventSourceMappings(profile, region, functionName);
}

export async function setReservedConcurrency(profile: string, region: string, functionName: string, reservedConcurrentExecutions: number): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  await client.send(new PutFunctionConcurrencyCommand({ FunctionName: functionName, ReservedConcurrentExecutions: reservedConcurrentExecutions }));
  return getFunctionDetail(profile, region, functionName);
}

export async function removeReservedConcurrency(profile: string, region: string, functionName: string): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  await client.send(new DeleteFunctionConcurrencyCommand({ FunctionName: functionName }));
  return getFunctionDetail(profile, region, functionName);
}

export async function addFunctionTag(profile: string, region: string, functionArn: string, functionName: string, key: string, value: string): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  await client.send(new TagResourceCommand({ Resource: functionArn, Tags: { [key]: value } }));
  return getFunctionDetail(profile, region, functionName);
}

export async function removeFunctionTag(profile: string, region: string, functionArn: string, functionName: string, key: string): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  await client.send(new UntagResourceCommand({ Resource: functionArn, TagKeys: [key] }));
  return getFunctionDetail(profile, region, functionName);
}

export async function deleteFunction(profile: string, region: string, functionName: string): Promise<void> {
  const client = createLambdaClient(profile, region);
  await client.send(new DeleteFunctionCommand({ FunctionName: functionName }));
}

/**
 * Same heuristic git/GitHub use (and `codecommit.ts`'s `getFile` already
 * relies on): a NUL byte anywhere in the first few KB means binary.
 */
function isLikelyBinaryContent(bytes: Uint8Array): boolean {
  const sampleLength = Math.min(bytes.length, 8000);
  for (let i = 0; i < sampleLength; i++) {
    if (bytes[i] === 0) return true;
  }
  return false;
}

/**
 * Deployment package zips keyed by function+region+profile+LastModified (so
 * a redeploy naturally busts the cache without any manual invalidation) and
 * held for a couple minutes - browsing a function's Code tab clicks through
 * several files, and re-downloading+re-unzipping a package that can run into
 * the tens of MB (node_modules bundled in) on every single click would be
 * slow and wasteful. `Code.Location` is itself a short-lived presigned S3
 * URL, so this cache never meaningfully outlives what the console's own
 * "Download" link would anyway.
 */
const codeZipCache = new Map<string, { zip: JSZip; expiresAt: number }>();
const CODE_ZIP_CACHE_TTL_MS = 2 * 60 * 1000;

async function loadCodeZip(profile: string, region: string, functionName: string): Promise<JSZip> {
  const client = createLambdaClient(profile, region);
  const response = await client.send(new GetFunctionCommand({ FunctionName: functionName }));
  const location = response.Code?.Location;
  if (!location) {
    throw new Error('No source code location is available for this function (container image functions have no deployment zip).');
  }

  const cacheKey = `${profile}:${region}:${functionName}:${response.Configuration?.LastModified || ''}`;
  const cached = codeZipCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.zip;
  }

  const res = await fetch(location);
  if (!res.ok) {
    throw new Error(`Failed to download the function's code (HTTP ${res.status}).`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  const zip = await JSZip.loadAsync(bytes);
  codeZipCache.set(cacheKey, { zip, expiresAt: Date.now() + CODE_ZIP_CACHE_TTL_MS });
  return zip;
}

export async function listCodeEntries(profile: string, region: string, functionName: string): Promise<ZipEntry[]> {
  const zip = await loadCodeZip(profile, region, functionName);
  const entries: ZipEntry[] = [];
  zip.forEach((relativePath, file) => {
    entries.push({ path: relativePath, isDirectory: file.dir });
  });
  entries.sort((a, b) => a.path.localeCompare(b.path));
  return entries;
}

const MAX_CODE_ENTRY_PREVIEW_SIZE = 1024 * 1024; // 1MB, matches S3's zip entry preview cap

export async function getCodeEntryContent(profile: string, region: string, functionName: string, path: string): Promise<ZipEntryContent> {
  const zip = await loadCodeZip(profile, region, functionName);
  const file = zip.file(path);
  if (!file) {
    throw new Error(`Entry not found in the deployment package: ${path}`);
  }

  const bytes = await file.async('uint8array');
  if (isLikelyBinaryContent(bytes)) {
    return { path, content: '[Binary file - preview not available]', isTruncated: false };
  }

  const content = Buffer.from(bytes).toString('utf-8');
  const isTruncated = content.length > MAX_CODE_ENTRY_PREVIEW_SIZE;
  return { path, content: isTruncated ? content.slice(0, MAX_CODE_ENTRY_PREVIEW_SIZE) : content, isTruncated };
}

/**
 * Backs the "Open in VS Code" button - the same idea as the console's own
 * "Open in Visual Studio Code" link, except there's no IDE-extension deep
 * link to lean on here, so the deployment package is unzipped straight to
 * disk and the Swift side just points a real VS Code window at the folder.
 * This is also the honest way to let binary entries (.NET/.NET-compiled
 * assemblies, Java .class/.jar, etc.) be "opened" at all - the in-app
 * preview refuses them (`getCodeEntryContent`'s binary check), but VS Code
 * can still show the file tree around them, run its own hex/binary viewer,
 * or open siblings that *are* text.
 *
 * Sidecar and Swift app run on the same Mac (this endpoint would make no
 * sense as a remote API), so returning a local filesystem path is safe and
 * simple - no upload/download step needed either direction.
 */
export async function exportCodeToLocalDirectory(profile: string, region: string, functionName: string): Promise<string> {
  const zip = await loadCodeZip(profile, region, functionName);
  const targetDir = join(tmpdir(), 'awsvisualizer-lambda-code', functionName);

  // Wiped and rewritten on every call (not reused/appended) so a stale
  // extraction from a previous deploy of the same function never lingers
  // and gets mistaken for current code.
  await fsPromises.rm(targetDir, { recursive: true, force: true });
  await fsPromises.mkdir(targetDir, { recursive: true });

  const fileEntries: { relativePath: string; file: JSZip.JSZipObject }[] = [];
  zip.forEach((relativePath, file) => {
    if (!file.dir) fileEntries.push({ relativePath, file });
  });

  // Writing to disk is I/O, not a chain of AWS API calls, so this doesn't
  // carry the "sequential AWS call timeout" risk documented elsewhere in
  // this file - the batching here is just to avoid opening thousands of
  // file handles at once for node_modules-heavy packages.
  const resolvedTargetDir = resolve(targetDir);
  const BATCH_SIZE = 25;
  for (let i = 0; i < fileEntries.length; i += BATCH_SIZE) {
    await Promise.all(fileEntries.slice(i, i + BATCH_SIZE).map(async ({ relativePath, file }) => {
      const destination = resolve(targetDir, relativePath);
      // Zip-slip guard - a `../`-laden entry name could otherwise resolve
      // outside targetDir. AWS's own deployment packages wouldn't do this,
      // but there's no reason to trust an arbitrary zip's paths blindly.
      if (destination !== resolvedTargetDir && !destination.startsWith(resolvedTargetDir + sep)) {
        return;
      }
      await fsPromises.mkdir(dirname(destination), { recursive: true });
      const bytes = await file.async('nodebuffer');
      await fsPromises.writeFile(destination, bytes);
    }));
  }

  return targetDir;
}

/** Maps a runtime family to the source file extension `createFunctionFromInlineCode` should zip it as. */
function extensionForRuntime(runtime: string): string {
  if (runtime.startsWith('python')) return '.py';
  if (runtime.startsWith('ruby')) return '.rb';
  if (runtime.startsWith('nodejs')) return '.js';
  return '.js';
}

/**
 * "Author from scratch" analog to the console's inline code editor - there's
 * no local checkout to zip (unlike CodeCommit's Workspace), so the pasted
 * source is zipped in-memory with the same `jszip` already used for S3's
 * archive browsing, then sent as `CreateFunctionCommand`'s `ZipFile` bytes.
 * The file name inside the zip is derived from the handler's module part
 * (`index.handler` -> `index.js`) since that's what the runtime looks up.
 */
export async function createFunctionFromInlineCode(
  profile: string,
  region: string,
  params: {
    functionName: string;
    runtime: string;
    handler: string;
    role: string;
    code: string;
    memorySize?: number;
    timeout?: number;
    description?: string;
  }
): Promise<LambdaFunctionDetail> {
  const client = createLambdaClient(profile, region);
  const moduleName = params.handler.split('.')[0] || 'index';
  const fileName = `${moduleName}${extensionForRuntime(params.runtime)}`;

  const zip = new JSZip();
  zip.file(fileName, params.code);
  const zipBuffer = await zip.generateAsync({ type: 'nodebuffer' });

  await client.send(new CreateFunctionCommand({
    FunctionName: params.functionName,
    Runtime: params.runtime as Runtime,
    Handler: params.handler,
    Role: params.role,
    Code: { ZipFile: zipBuffer },
    MemorySize: params.memorySize,
    Timeout: params.timeout,
    Description: params.description,
  }));

  return getFunctionDetail(profile, region, params.functionName);
}
