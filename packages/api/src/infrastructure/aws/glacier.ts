import {
  GlacierClient,
  ListVaultsCommand,
  DescribeVaultCommand,
  GetVaultAccessPolicyCommand,
  GetVaultLockCommand,
  GetVaultNotificationsCommand,
  ListTagsForVaultCommand,
  ListJobsCommand,
  DescribeJobCommand,
  InitiateJobCommand,
  GetJobOutputCommand,
  AddTagsToVaultCommand,
  RemoveTagsFromVaultCommand,
  type DescribeVaultOutput,
} from '@aws-sdk/client-glacier';
import { cachedCredentials } from './credential-cache.js';
import type { GlacierVault, GlacierVaultDetail, GlacierJob, GlacierInventory } from '../../domain/entities/index.js';

/** `-` = the account the credentials belong to. */
const accountId = '-';
const INVENTORY_MAX_BYTES = 20 * 1024 * 1024;
const INVENTORY_MAX_ARCHIVES = 5000;

function createClient(profile: string, region: string): GlacierClient {
  return new GlacierClient({ region, credentials: cachedCredentials(profile) });
}

const httpError = (message: string, status: number) => Object.assign(new Error(message), { $metadata: { httpStatusCode: status } });
const isNotFound = (err: unknown) => (err as { name?: string })?.name === 'ResourceNotFoundException';
const orUndefined = <T>(p: Promise<T>) => p.catch((err) => (isNotFound(err) ? undefined : Promise.reject(err)));

function mapVault(v: DescribeVaultOutput): GlacierVault {
  return {
    vaultName: v.VaultName || '',
    vaultArn: v.VaultARN,
    creationDate: v.CreationDate,
    lastInventoryDate: v.LastInventoryDate,
    numberOfArchives: v.NumberOfArchives,
    sizeInBytes: v.SizeInBytes,
  };
}

export async function listGlacierVaults(profile: string, region: string): Promise<GlacierVault[]> {
  const client = createClient(profile, region);
  const out: GlacierVault[] = [];
  let marker: string | undefined;
  do {
    const res = await client.send(new ListVaultsCommand({ accountId, marker }));
    out.push(...(res.VaultList || []).map(mapVault));
    marker = res.Marker;
  } while (marker);
  return out.sort((a, b) => a.vaultName.localeCompare(b.vaultName));
}

export async function getGlacierVault(profile: string, region: string, vaultName: string): Promise<GlacierVaultDetail> {
  const client = createClient(profile, region);
  const [vault, policy, lock, notif, tags] = await Promise.all([
    client.send(new DescribeVaultCommand({ accountId, vaultName })),
    orUndefined(client.send(new GetVaultAccessPolicyCommand({ accountId, vaultName }))),
    orUndefined(client.send(new GetVaultLockCommand({ accountId, vaultName }))),
    orUndefined(client.send(new GetVaultNotificationsCommand({ accountId, vaultName }))),
    client.send(new ListTagsForVaultCommand({ accountId, vaultName })).catch(() => undefined),
  ]);
  return {
    ...mapVault(vault),
    accessPolicy: policy?.policy?.Policy,
    lock: lock ? { state: lock.State, policy: lock.Policy, creationDate: lock.CreationDate, expirationDate: lock.ExpirationDate } : undefined,
    notifications: notif?.vaultNotificationConfig
      ? { snsTopic: notif.vaultNotificationConfig.SNSTopic, events: notif.vaultNotificationConfig.Events || [] }
      : undefined,
    tags: Object.entries(tags?.Tags || {}).map(([key, value]) => ({ key, value })),
  };
}

export async function listGlacierJobs(profile: string, region: string, vaultName: string): Promise<GlacierJob[]> {
  const client = createClient(profile, region);
  const out: GlacierJob[] = [];
  let marker: string | undefined;
  do {
    const res = await client.send(new ListJobsCommand({ accountId, vaultName, marker }));
    for (const j of res.JobList || []) {
      out.push({
        jobId: j.JobId || '',
        action: j.Action,
        description: j.JobDescription,
        statusCode: j.StatusCode,
        statusMessage: j.StatusMessage,
        completed: j.Completed,
        creationDate: j.CreationDate,
        completionDate: j.CompletionDate,
        tier: j.Tier,
        archiveId: j.ArchiveId,
        archiveSizeInBytes: j.ArchiveSizeInBytes,
        inventorySizeInBytes: j.InventorySizeInBytes,
      });
    }
    marker = res.Marker;
  } while (marker);
  return out.sort((a, b) => (b.creationDate || '').localeCompare(a.creationDate || ''));
}

/** Starts an inventory-retrieval job - Glacier takes hours to prepare it. */
export async function requestGlacierInventory(profile: string, region: string, vaultName: string): Promise<{ jobId?: string }> {
  const res = await createClient(profile, region).send(
    new InitiateJobCommand({
      accountId,
      vaultName,
      jobParameters: { Type: 'inventory-retrieval', Format: 'JSON', Description: 'Requested from AWS Visualizer' },
    }),
  );
  return { jobId: res.jobId };
}

interface InventoryJson {
  InventoryDate?: string;
  ArchiveList?: { ArchiveId: string; ArchiveDescription?: string; CreationDate?: string; Size?: number; SHA256TreeHash?: string }[];
}

export async function getGlacierInventory(profile: string, region: string, vaultName: string, jobId: string): Promise<GlacierInventory> {
  const client = createClient(profile, region);
  const job = await client.send(new DescribeJobCommand({ accountId, vaultName, jobId }));
  if (job.Action !== 'InventoryRetrieval') throw httpError('Only inventory jobs can be viewed here', 400);
  if (!job.Completed || job.StatusCode !== 'Succeeded') {
    throw httpError(`Inventory job is ${job.StatusCode || 'not finished'}`, 409);
  }
  if ((job.InventorySizeInBytes || 0) > INVENTORY_MAX_BYTES) {
    throw httpError('Inventory is larger than 20 MB - download it with the AWS CLI', 413);
  }
  const res = await client.send(new GetJobOutputCommand({ accountId, vaultName, jobId }));
  const text = (await res.body?.transformToString()) || '{}';
  const json = JSON.parse(text) as InventoryJson;
  const list = json.ArchiveList || [];
  return {
    inventoryDate: json.InventoryDate,
    archives: list.slice(0, INVENTORY_MAX_ARCHIVES).map((a) => ({
      archiveId: a.ArchiveId,
      description: a.ArchiveDescription,
      creationDate: a.CreationDate,
      size: a.Size,
      sha256TreeHash: a.SHA256TreeHash,
    })),
    truncated: list.length > INVENTORY_MAX_ARCHIVES,
  };
}

export async function addGlacierTag(profile: string, region: string, vaultName: string, key: string, value: string): Promise<GlacierVaultDetail> {
  await createClient(profile, region).send(new AddTagsToVaultCommand({ accountId, vaultName, Tags: { [key]: value } }));
  return getGlacierVault(profile, region, vaultName);
}

export async function removeGlacierTag(profile: string, region: string, vaultName: string, key: string): Promise<GlacierVaultDetail> {
  await createClient(profile, region).send(new RemoveTagsFromVaultCommand({ accountId, vaultName, TagKeys: [key] }));
  return getGlacierVault(profile, region, vaultName);
}
