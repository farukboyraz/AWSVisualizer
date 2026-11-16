import {
  SecretsManagerClient,
  ListSecretsCommand,
  DescribeSecretCommand,
  UpdateSecretCommand,
  DeleteSecretCommand,
  RestoreSecretCommand,
  TagResourceCommand,
  UntagResourceCommand,
  GetSecretValueCommand,
  PutSecretValueCommand,
  CreateSecretCommand,
  GetResourcePolicyCommand,
  PutResourcePolicyCommand,
  DeleteResourcePolicyCommand,
  RotateSecretCommand,
  CancelRotateSecretCommand,
} from '@aws-sdk/client-secrets-manager';
import { cachedCredentials } from './credential-cache.js';
import type {
  SecretsManagerSecret,
  SecretsManagerSecretDetail,
  SecretsManagerSecretValue,
  SecretsManagerResourcePolicy,
  SecretsManagerTag,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): SecretsManagerClient {
  return new SecretsManagerClient({ region, credentials: cachedCredentials(profile) });
}

export async function listSecrets(profile: string, region: string): Promise<SecretsManagerSecret[]> {
  const client = createClient(profile, region);
  const response = await client.send(new ListSecretsCommand({}));

  return (response.SecretList || []).map((s) => ({
    name: s.Name || '',
    arn: s.ARN || '',
    description: s.Description,
    lastChangedDate: s.LastChangedDate?.toISOString(),
  }));
}

export async function getSecretDetail(profile: string, region: string, secretId: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  const response = await client.send(new DescribeSecretCommand({ SecretId: secretId }));

  const versionStages = Object.entries(response.VersionIdsToStages || {}).map(([versionId, stages]) => ({
    versionId,
    stages,
  }));

  return {
    name: response.Name || secretId,
    arn: response.ARN || '',
    description: response.Description,
    kmsKeyId: response.KmsKeyId,
    rotationEnabled: response.RotationEnabled,
    rotationLambdaArn: response.RotationLambdaARN,
    lastRotatedDate: response.LastRotatedDate?.toISOString(),
    lastChangedDate: response.LastChangedDate?.toISOString(),
    lastAccessedDate: response.LastAccessedDate?.toISOString(),
    deletedDate: response.DeletedDate?.toISOString(),
    nextRotationDate: response.NextRotationDate?.toISOString(),
    createdDate: response.CreatedDate?.toISOString(),
    tags: (response.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
    versionStages,
  };
}

export async function updateSecretDescription(profile: string, region: string, secretId: string, description: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(new UpdateSecretCommand({ SecretId: secretId, Description: description }));
  return getSecretDetail(profile, region, secretId);
}

export async function addSecretTag(profile: string, region: string, secretId: string, key: string, value: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ SecretId: secretId, Tags: [{ Key: key, Value: value }] }));
  return getSecretDetail(profile, region, secretId);
}

export async function removeSecretTag(profile: string, region: string, secretId: string, key: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ SecretId: secretId, TagKeys: [key] }));
  return getSecretDetail(profile, region, secretId);
}

// Always goes through Secrets Manager's recovery-window deletion (7-30
// days, restorable via RestoreSecret) - ForceDeleteWithoutRecovery is
// deliberately not exposed, it's a one-way door with no undo.
export async function deleteSecret(profile: string, region: string, secretId: string, recoveryWindowInDays: number): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteSecretCommand({ SecretId: secretId, RecoveryWindowInDays: recoveryWindowInDays }));
}

export async function restoreSecret(profile: string, region: string, secretId: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(new RestoreSecretCommand({ SecretId: secretId }));
  return getSecretDetail(profile, region, secretId);
}

// Only called when the user explicitly clicks "Reveal" in the UI - never as
// part of loading a secret's detail page. IAM still enforces the real
// boundary (a caller without secretsmanager:GetSecretValue gets AccessDenied
// same as anywhere else), this is just this app's own choice not to fetch a
// value nobody asked to see yet.
export async function getSecretValue(profile: string, region: string, secretId: string): Promise<SecretsManagerSecretValue> {
  const client = createClient(profile, region);
  const response = await client.send(new GetSecretValueCommand({ SecretId: secretId }));

  return {
    secretString: response.SecretString,
    secretBinary: response.SecretBinary ? Buffer.from(response.SecretBinary).toString('base64') : undefined,
    versionId: response.VersionId,
  };
}

/**
 * The console's "Edit" on the secret value: stores a new version that
 * becomes AWSCURRENT (the old one moves to AWSPREVIOUS, so it's still
 * recoverable from the Versions tab / CLI). Returns the stored value.
 */
export async function putSecretValue(profile: string, region: string, secretId: string, secretString: string): Promise<SecretsManagerSecretValue> {
  const client = createClient(profile, region);
  await client.send(new PutSecretValueCommand({ SecretId: secretId, SecretString: secretString }));
  return getSecretValue(profile, region, secretId);
}

export async function createSecret(
  profile: string,
  region: string,
  name: string,
  description: string | undefined,
  secretString: string,
  kmsKeyId: string | undefined,
  tags: SecretsManagerTag[] | undefined
): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(
    new CreateSecretCommand({
      Name: name,
      Description: description || undefined,
      SecretString: secretString,
      KmsKeyId: kmsKeyId || undefined,
      Tags: tags && tags.length > 0 ? tags.map((t) => ({ Key: t.key, Value: t.value })) : undefined,
    })
  );
  return getSecretDetail(profile, region, name);
}

// The console's "Resource permissions" tab - a resource-based policy on the
// secret itself, same JSON-editing pattern as the KMS key policy tab
// (`kms.ts`'s `getKeyPolicy`/`putKeyPolicy`). Most secrets have no policy at
// all (undefined `policy`) until one is explicitly attached.
export async function getResourcePolicy(profile: string, region: string, secretId: string): Promise<SecretsManagerResourcePolicy> {
  const client = createClient(profile, region);
  const response = await client.send(new GetResourcePolicyCommand({ SecretId: secretId }));
  return { policy: response.ResourcePolicy };
}

export async function putResourcePolicy(profile: string, region: string, secretId: string, policy: string): Promise<SecretsManagerResourcePolicy> {
  const client = createClient(profile, region);
  await client.send(new PutResourcePolicyCommand({ SecretId: secretId, ResourcePolicy: policy }));
  return getResourcePolicy(profile, region, secretId);
}

export async function deleteResourcePolicy(profile: string, region: string, secretId: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteResourcePolicyCommand({ SecretId: secretId }));
}

// Enables rotation against an *existing* Lambda function's ARN - creating a
// brand-new rotation Lambda from scratch is a multi-step wizard (console
// offers to generate one for RDS/DocumentDB/Redshift secrets) that's out of
// scope here, same "existing resource, not a creation wizard" boundary as
// CloudWatch alarms' existing SNS topic ARNs. `RotateImmediately: false` so
// enabling rotation doesn't also force an unexpected rotation right away.
export async function updateRotation(
  profile: string,
  region: string,
  secretId: string,
  rotationLambdaARN: string,
  automaticallyAfterDays: number
): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(
    new RotateSecretCommand({
      SecretId: secretId,
      RotationLambdaARN: rotationLambdaARN,
      RotationRules: { AutomaticallyAfterDays: automaticallyAfterDays },
      RotateImmediately: false,
    })
  );
  return getSecretDetail(profile, region, secretId);
}

export async function rotateSecretNow(profile: string, region: string, secretId: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(new RotateSecretCommand({ SecretId: secretId, RotateImmediately: true }));
  return getSecretDetail(profile, region, secretId);
}

export async function cancelRotation(profile: string, region: string, secretId: string): Promise<SecretsManagerSecretDetail> {
  const client = createClient(profile, region);
  await client.send(new CancelRotateSecretCommand({ SecretId: secretId }));
  return getSecretDetail(profile, region, secretId);
}
