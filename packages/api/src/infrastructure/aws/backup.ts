import {
  BackupClient,
  ListBackupPlansCommand,
  GetBackupPlanCommand,
  ListBackupSelectionsCommand,
  GetBackupSelectionCommand,
  ListBackupVaultsCommand,
  DescribeBackupVaultCommand,
  ListRecoveryPointsByBackupVaultCommand,
  GetBackupVaultAccessPolicyCommand,
  GetBackupVaultNotificationsCommand,
  ListProtectedResourcesCommand,
  ListBackupJobsCommand,
  ListRestoreJobsCommand,
  ListCopyJobsCommand,
  ListTagsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type BackupVaultListMember,
  type DescribeBackupVaultOutput,
  type Lifecycle,
} from '@aws-sdk/client-backup';
import { cachedCredentials } from './credential-cache.js';
import type {
  BackupOverview,
  BackupPlanSummary,
  BackupPlanDetail,
  BackupVaultSummary,
  BackupVaultDetail,
  BackupJobInfo,
  StorageTag,
} from '../../domain/entities/index.js';

export type BackupJobKind = 'backup' | 'restore' | 'copy';

const RECOVERY_POINT_LIMIT = 500;
const JOB_LIMIT = 500;
const JOB_WINDOW_DAYS = 30;

function createClient(profile: string, region: string): BackupClient {
  return new BackupClient({ region, credentials: cachedCredentials(profile) });
}

const iso = (d?: Date) => d?.toISOString();
const errorText = (label: string, err: unknown) => `${label}: ${err instanceof Error ? err.message : String(err)}`;
const isNotFound = (err: unknown) => (err as { name?: string })?.name === 'ResourceNotFoundException';
const vaultName = (arn?: string) => arn?.split(':').pop();

async function tagsOf(client: BackupClient, arn?: string): Promise<StorageTag[]> {
  if (!arn) return [];
  const res = await client.send(new ListTagsCommand({ ResourceArn: arn })).catch(() => undefined);
  return Object.entries(res?.Tags || {}).map(([key, value]) => ({ key, value }));
}

function mapVault(v: BackupVaultListMember | DescribeBackupVaultOutput): BackupVaultSummary {
  return {
    backupVaultName: v.BackupVaultName || '',
    backupVaultArn: v.BackupVaultArn,
    vaultType: v.VaultType,
    vaultState: v.VaultState,
    creationDate: iso(v.CreationDate),
    encryptionKeyArn: v.EncryptionKeyArn,
    numberOfRecoveryPoints: v.NumberOfRecoveryPoints,
    locked: v.Locked,
    minRetentionDays: v.MinRetentionDays,
    maxRetentionDays: v.MaxRetentionDays,
    lockDate: iso(v.LockDate),
  };
}

export async function listBackupPlans(profile: string, region: string): Promise<BackupPlanSummary[]> {
  const client = createClient(profile, region);
  const out: BackupPlanSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListBackupPlansCommand({ NextToken }));
    for (const p of res.BackupPlansList || []) {
      out.push({
        backupPlanId: p.BackupPlanId || '',
        backupPlanArn: p.BackupPlanArn,
        backupPlanName: p.BackupPlanName,
        versionId: p.VersionId,
        creationDate: iso(p.CreationDate),
        lastExecutionDate: iso(p.LastExecutionDate),
      });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => (a.backupPlanName || '').localeCompare(b.backupPlanName || ''));
}

export async function listBackupVaults(profile: string, region: string): Promise<BackupVaultSummary[]> {
  const client = createClient(profile, region);
  const out: BackupVaultSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListBackupVaultsCommand({ NextToken }));
    out.push(...(res.BackupVaultList || []).map(mapVault));
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => a.backupVaultName.localeCompare(b.backupVaultName));
}

async function listProtectedResources(client: BackupClient): Promise<BackupOverview['protectedResources']> {
  const out: BackupOverview['protectedResources'] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListProtectedResourcesCommand({ NextToken }));
    for (const r of res.Results || []) {
      out.push({
        resourceArn: r.ResourceArn || '',
        resourceName: r.ResourceName,
        resourceType: r.ResourceType,
        lastBackupTime: iso(r.LastBackupTime),
        lastBackupVault: vaultName(r.LastBackupVaultArn),
      });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => (b.lastBackupTime || '').localeCompare(a.lastBackupTime || ''));
}

/** Backup plans, vaults and protected resources for the list panel; each part may fail on its own. */
export async function getBackupOverview(profile: string, region: string): Promise<BackupOverview> {
  const client = createClient(profile, region);
  const [plans, vaults, resources] = await Promise.allSettled([
    listBackupPlans(profile, region),
    listBackupVaults(profile, region),
    listProtectedResources(client),
  ]);
  const errors: string[] = [];
  const pick = <T>(r: PromiseSettledResult<T[]>, label: string): T[] => {
    if (r.status === 'fulfilled') return r.value;
    errors.push(errorText(label, r.reason));
    return [];
  };
  return {
    plans: pick(plans, 'Backup plans'),
    vaults: pick(vaults, 'Backup vaults'),
    protectedResources: pick(resources, 'Protected resources'),
    errors,
  };
}

/** Plans plus vaults - what the dashboard counts for Backup. */
export async function listBackupItems(profile: string, region: string): Promise<unknown[]> {
  const [plans, vaults] = await Promise.all([listBackupPlans(profile, region), listBackupVaults(profile, region)]);
  return [...plans, ...vaults];
}

function lifecycleText(l?: Lifecycle): { cold?: number; del?: number } {
  return { cold: l?.MoveToColdStorageAfterDays, del: l?.DeleteAfterDays };
}

export async function getBackupPlan(profile: string, region: string, planId: string): Promise<BackupPlanDetail> {
  const client = createClient(profile, region);
  const plan = await client.send(new GetBackupPlanCommand({ BackupPlanId: planId }));

  const selectionIds: { id: string; name?: string; role?: string }[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListBackupSelectionsCommand({ BackupPlanId: planId, NextToken }));
    for (const s of res.BackupSelectionsList || []) selectionIds.push({ id: s.SelectionId || '', name: s.SelectionName, role: s.IamRoleArn });
    NextToken = res.NextToken;
  } while (NextToken);

  const selections = await Promise.all(
    selectionIds.map(async (s) => {
      const res = await client.send(new GetBackupSelectionCommand({ BackupPlanId: planId, SelectionId: s.id })).catch(() => undefined);
      const sel = res?.BackupSelection;
      const c = sel?.Conditions;
      const conditions = [
        ...(sel?.ListOfTags || []).map((t) => `tag ${t.ConditionKey} ${t.ConditionType === 'STRINGEQUALS' ? '=' : t.ConditionType} ${t.ConditionValue}`),
        ...(c?.StringEquals || []).map((p) => `${p.ConditionKey} = ${p.ConditionValue}`),
        ...(c?.StringNotEquals || []).map((p) => `${p.ConditionKey} ≠ ${p.ConditionValue}`),
        ...(c?.StringLike || []).map((p) => `${p.ConditionKey} like ${p.ConditionValue}`),
        ...(c?.StringNotLike || []).map((p) => `${p.ConditionKey} not like ${p.ConditionValue}`),
      ];
      return {
        selectionId: s.id,
        selectionName: sel?.SelectionName ?? s.name,
        iamRoleArn: sel?.IamRoleArn ?? s.role,
        resources: sel?.Resources || [],
        notResources: sel?.NotResources || [],
        conditions,
      };
    }),
  );

  return {
    backupPlanId: plan.BackupPlanId || planId,
    backupPlanArn: plan.BackupPlanArn,
    backupPlanName: plan.BackupPlan?.BackupPlanName,
    versionId: plan.VersionId,
    creationDate: iso(plan.CreationDate),
    lastExecutionDate: iso(plan.LastExecutionDate),
    rules: (plan.BackupPlan?.Rules || []).map((r) => {
      const l = lifecycleText(r.Lifecycle);
      return {
        ruleName: r.RuleName || '',
        targetVault: r.TargetBackupVaultName,
        schedule: r.ScheduleExpression,
        timezone: r.ScheduleExpressionTimezone,
        startWindowMinutes: r.StartWindowMinutes,
        completionWindowMinutes: r.CompletionWindowMinutes,
        moveToColdStorageAfterDays: l.cold,
        deleteAfterDays: l.del,
        continuousBackup: r.EnableContinuousBackup,
        copyTo: (r.CopyActions || []).map((a) => {
          const cl = lifecycleText(a.Lifecycle);
          const arn = a.DestinationBackupVaultArn || '';
          const regionOf = arn.split(':')[3];
          return `${vaultName(arn)}${regionOf ? ` (${regionOf})` : ''}${cl.del ? `, delete after ${cl.del} days` : ''}`;
        }),
      };
    }),
    selections,
    advancedSettings: (plan.AdvancedBackupSettings || []).map(
      (s) => `${s.ResourceType}: ${Object.entries(s.BackupOptions || {}).map(([k, v]) => `${k}=${v}`).join(', ')}`,
    ),
    tags: await tagsOf(client, plan.BackupPlanArn),
  };
}

export async function getBackupVault(profile: string, region: string, name: string): Promise<BackupVaultDetail> {
  const client = createClient(profile, region);
  const vault = await client.send(new DescribeBackupVaultCommand({ BackupVaultName: name }));
  const errors: string[] = [];

  const recoveryPoints = async () => {
    const out: BackupVaultDetail['recoveryPoints'] = [];
    let NextToken: string | undefined;
    do {
      const res = await client.send(new ListRecoveryPointsByBackupVaultCommand({ BackupVaultName: name, NextToken, MaxResults: 200 }));
      for (const r of res.RecoveryPoints || []) {
        out.push({
          recoveryPointArn: r.RecoveryPointArn || '',
          resourceArn: r.ResourceArn,
          resourceName: r.ResourceName,
          resourceType: r.ResourceType,
          status: r.Status,
          creationDate: iso(r.CreationDate),
          completionDate: iso(r.CompletionDate),
          backupSizeInBytes: r.BackupSizeInBytes,
          deleteAt: iso(r.CalculatedLifecycle?.DeleteAt),
          moveToColdStorageAt: iso(r.CalculatedLifecycle?.MoveToColdStorageAt),
          isEncrypted: r.IsEncrypted,
          createdByPlan: r.CreatedBy?.BackupPlanId,
        });
      }
      NextToken = res.NextToken;
    } while (NextToken && out.length < RECOVERY_POINT_LIMIT);
    return { points: out.slice(0, RECOVERY_POINT_LIMIT), truncated: Boolean(NextToken) };
  };

  const [rp, policy, notif, tags] = await Promise.allSettled([
    recoveryPoints(),
    client.send(new GetBackupVaultAccessPolicyCommand({ BackupVaultName: name })),
    client.send(new GetBackupVaultNotificationsCommand({ BackupVaultName: name })),
    tagsOf(client, vault.BackupVaultArn),
  ]);
  if (rp.status === 'rejected') errors.push(errorText('Recovery points', rp.reason));
  if (policy.status === 'rejected' && !isNotFound(policy.reason)) errors.push(errorText('Access policy', policy.reason));
  if (notif.status === 'rejected' && !isNotFound(notif.reason)) errors.push(errorText('Notifications', notif.reason));

  return {
    ...mapVault(vault),
    recoveryPoints: rp.status === 'fulfilled' ? rp.value.points.sort((a, b) => (b.creationDate || '').localeCompare(a.creationDate || '')) : [],
    recoveryPointsTruncated: rp.status === 'fulfilled' && rp.value.truncated,
    accessPolicy: policy.status === 'fulfilled' ? policy.value.Policy : undefined,
    notifications:
      notif.status === 'fulfilled'
        ? { snsTopicArn: notif.value.SNSTopicArn, events: notif.value.BackupVaultEvents || [] }
        : undefined,
    tags: tags.status === 'fulfilled' ? tags.value : [],
    errors,
  };
}

/** Jobs created in the last JOB_WINDOW_DAYS days, newest first. */
export async function listBackupJobs(profile: string, region: string, kind: BackupJobKind): Promise<BackupJobInfo[]> {
  const client = createClient(profile, region);
  const after = new Date(Date.now() - JOB_WINDOW_DAYS * 86_400_000);
  const out: BackupJobInfo[] = [];
  let NextToken: string | undefined;
  do {
    if (kind === 'backup') {
      const res = await client.send(new ListBackupJobsCommand({ ByCreatedAfter: after, NextToken, MaxResults: 200 }));
      for (const j of res.BackupJobs || []) {
        out.push({
          jobId: j.BackupJobId || '',
          kind,
          state: j.State,
          statusMessage: j.StatusMessage,
          resourceArn: j.ResourceArn,
          resourceName: j.ResourceName,
          resourceType: j.ResourceType,
          vault: j.BackupVaultName,
          creationDate: iso(j.CreationDate),
          completionDate: iso(j.CompletionDate),
          percentDone: j.PercentDone,
          sizeInBytes: j.BackupSizeInBytes,
        });
      }
      NextToken = res.NextToken;
    } else if (kind === 'restore') {
      const res = await client.send(new ListRestoreJobsCommand({ ByCreatedAfter: after, NextToken, MaxResults: 200 }));
      for (const j of res.RestoreJobs || []) {
        out.push({
          jobId: j.RestoreJobId || '',
          kind,
          state: j.Status,
          statusMessage: j.StatusMessage,
          resourceArn: j.CreatedResourceArn,
          resourceType: j.ResourceType,
          creationDate: iso(j.CreationDate),
          completionDate: iso(j.CompletionDate),
          percentDone: j.PercentDone,
          sizeInBytes: j.BackupSizeInBytes,
        });
      }
      NextToken = res.NextToken;
    } else {
      const res = await client.send(new ListCopyJobsCommand({ ByCreatedAfter: after, NextToken, MaxResults: 200 }));
      for (const j of res.CopyJobs || []) {
        out.push({
          jobId: j.CopyJobId || '',
          kind,
          state: j.State,
          statusMessage: j.StatusMessage,
          resourceArn: j.ResourceArn,
          resourceName: j.ResourceName,
          resourceType: j.ResourceType,
          vault: `${vaultName(j.SourceBackupVaultArn)} → ${vaultName(j.DestinationBackupVaultArn)}`,
          creationDate: iso(j.CreationDate),
          completionDate: iso(j.CompletionDate),
          sizeInBytes: j.BackupSizeInBytes,
        });
      }
      NextToken = res.NextToken;
    }
  } while (NextToken && out.length < JOB_LIMIT);
  return out.sort((a, b) => (b.creationDate || '').localeCompare(a.creationDate || '')).slice(0, JOB_LIMIT);
}

export async function addBackupTag(profile: string, region: string, arn: string, key: string, value: string): Promise<void> {
  await createClient(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: { [key]: value } }));
}

export async function removeBackupTag(profile: string, region: string, arn: string, key: string): Promise<void> {
  await createClient(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeyList: [key] }));
}
