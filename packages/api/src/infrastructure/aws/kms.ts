import {
  KMSClient,
  ListKeysCommand,
  DescribeKeyCommand,
  GetKeyPolicyCommand,
  PutKeyPolicyCommand,
  ListAliasesCommand,
  CreateAliasCommand,
  DeleteAliasCommand,
  ListResourceTagsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  GetKeyRotationStatusCommand,
  EnableKeyRotationCommand,
  DisableKeyRotationCommand,
  EnableKeyCommand,
  DisableKeyCommand,
  ScheduleKeyDeletionCommand,
  CancelKeyDeletionCommand,
} from '@aws-sdk/client-kms';
import { cachedCredentials } from './credential-cache.js';
import type { KmsKey, KmsKeyDetail } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): KMSClient {
  return new KMSClient({ region, credentials: cachedCredentials(profile) });
}

export async function listKeys(profile: string, region: string): Promise<KmsKey[]> {
  const client = createClient(profile, region);
  const response = await client.send(new ListKeysCommand({}));

  return (response.Keys || []).map((k) => ({
    keyId: k.KeyId || '',
    keyArn: k.KeyArn || '',
  }));
}

export async function getKeyDetail(profile: string, region: string, keyId: string): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  const describeRes = await client.send(new DescribeKeyCommand({ KeyId: keyId }));
  const meta = describeRes.KeyMetadata;

  const [aliasesRes, tagsRes, rotationRes] = await Promise.all([
    client.send(new ListAliasesCommand({ KeyId: keyId })).catch(() => undefined),
    client.send(new ListResourceTagsCommand({ KeyId: keyId })).catch(() => undefined),
    client.send(new GetKeyRotationStatusCommand({ KeyId: keyId })).catch(() => undefined),
  ]);

  const aliases = (aliasesRes?.Aliases || []).map((a) => a.AliasName || '').filter(Boolean);
  const tags = (tagsRes?.Tags || []).map((t) => ({ key: t.TagKey || '', value: t.TagValue || '' }));

  return {
    keyId: meta?.KeyId || keyId,
    keyArn: meta?.Arn || '',
    description: meta?.Description,
    keyUsage: meta?.KeyUsage,
    keySpec: meta?.KeySpec,
    origin: meta?.Origin,
    keyManager: meta?.KeyManager,
    keyState: meta?.KeyState,
    enabled: meta?.Enabled ?? false,
    multiRegion: meta?.MultiRegion,
    creationDate: meta?.CreationDate?.toISOString(),
    deletionDate: meta?.DeletionDate?.toISOString(),
    rotationEnabled: rotationRes?.KeyRotationEnabled,
    rotationSupported: rotationRes !== undefined,
    aliases,
    tags,
    rotationPeriodInDays: rotationRes?.RotationPeriodInDays,
    nextRotationDate: rotationRes?.NextRotationDate?.toISOString(),
    encryptionAlgorithms: meta?.EncryptionAlgorithms || [],
    signingAlgorithms: meta?.SigningAlgorithms || [],
    macAlgorithms: meta?.MacAlgorithms || [],
    pendingDeletionWindowInDays: meta?.PendingDeletionWindowInDays,
  };
}

export async function getKeyPolicy(profile: string, region: string, keyId: string, policyName = 'default'): Promise<string> {
  const client = createClient(profile, region);
  const response = await client.send(new GetKeyPolicyCommand({ KeyId: keyId, PolicyName: policyName }));
  return response.Policy || '';
}

export async function updateKeyPolicy(profile: string, region: string, keyId: string, policy: string, policyName = 'default'): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new PutKeyPolicyCommand({ KeyId: keyId, PolicyName: policyName, Policy: policy }));
}

export async function setKeyEnabled(profile: string, region: string, keyId: string, enabled: boolean): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(enabled ? new EnableKeyCommand({ KeyId: keyId }) : new DisableKeyCommand({ KeyId: keyId }));
  return getKeyDetail(profile, region, keyId);
}

/** `rotationPeriodInDays` (90-2560) only applies when enabling; AWS defaults to 365. */
export async function setKeyRotation(profile: string, region: string, keyId: string, enabled: boolean, rotationPeriodInDays?: number): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(
    enabled
      ? new EnableKeyRotationCommand({ KeyId: keyId, RotationPeriodInDays: rotationPeriodInDays })
      : new DisableKeyRotationCommand({ KeyId: keyId })
  );
  return getKeyDetail(profile, region, keyId);
}

/** Waiting period 7-30 days (AWS default 30); the key is unusable meanwhile and can be cancelled. */
export async function scheduleKeyDeletion(profile: string, region: string, keyId: string, pendingWindowInDays: number): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(new ScheduleKeyDeletionCommand({ KeyId: keyId, PendingWindowInDays: pendingWindowInDays }));
  return getKeyDetail(profile, region, keyId);
}

/** Cancelling leaves the key Disabled, like the console. */
export async function cancelKeyDeletion(profile: string, region: string, keyId: string): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(new CancelKeyDeletionCommand({ KeyId: keyId }));
  return getKeyDetail(profile, region, keyId);
}

export async function addAlias(profile: string, region: string, keyId: string, aliasName: string): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  const normalized = aliasName.startsWith('alias/') ? aliasName : `alias/${aliasName}`;
  await client.send(new CreateAliasCommand({ AliasName: normalized, TargetKeyId: keyId }));
  return getKeyDetail(profile, region, keyId);
}

export async function removeAlias(profile: string, region: string, keyId: string, aliasName: string): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(new DeleteAliasCommand({ AliasName: aliasName }));
  return getKeyDetail(profile, region, keyId);
}

export async function addKeyTag(profile: string, region: string, keyId: string, key: string, value: string): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ KeyId: keyId, Tags: [{ TagKey: key, TagValue: value }] }));
  return getKeyDetail(profile, region, keyId);
}

export async function removeKeyTag(profile: string, region: string, keyId: string, key: string): Promise<KmsKeyDetail> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ KeyId: keyId, TagKeys: [key] }));
  return getKeyDetail(profile, region, keyId);
}
