import {
  DescribeTableCommand,
  DescribeContinuousBackupsCommand,
  DescribeTimeToLiveCommand,
  ListTagsOfResourceCommand,
  UpdateTableCommand,
  UpdateContinuousBackupsCommand,
  UpdateTimeToLiveCommand,
  ListBackupsCommand,
  CreateBackupCommand,
  DeleteBackupCommand,
  TagResourceCommand,
  UntagResourceCommand,
  QueryCommand,
  ExecuteStatementCommand,
  CreateTableCommand,
  DeleteTableCommand,
  type TableDescription,
  type AttributeValue,
  type ScalarAttributeType,
} from '@aws-sdk/client-dynamodb';
import { CloudWatchClient, GetMetricStatisticsCommand, type Statistic } from '@aws-sdk/client-cloudwatch';
import { marshall } from '@aws-sdk/util-dynamodb';
import { cachedCredentials } from './credential-cache.js';
import { createDdbClient, matchesAll, unmarshallPlain } from './dynamodb.js';
import type {
  DdbIndexInfo,
  DdbTableDetail,
  DdbBackup,
  DdbMetricsSummary,
  DdbQueryRequest,
  DdbPageResult,
} from '../../domain/entities/index.js';

function badRequest(message: string): Error {
  return Object.assign(new Error(message), { name: 'ValidationException', $metadata: { httpStatusCode: 400 } });
}

const keySchemaOf = (ks?: { AttributeName?: string; KeyType?: string }[]) =>
  (ks || []).map((k) => ({ attributeName: k.AttributeName || '', keyType: k.KeyType || '' }));

export function describeIndexes(table: TableDescription): DdbIndexInfo[] {
  const gsis = (table.GlobalSecondaryIndexes || []).map((g) => ({
    indexName: g.IndexName || '',
    indexType: 'GSI',
    keySchema: keySchemaOf(g.KeySchema),
    projectionType: g.Projection?.ProjectionType,
    nonKeyAttributes: g.Projection?.NonKeyAttributes || [],
    indexStatus: g.IndexStatus,
    itemCount: g.ItemCount,
    sizeBytes: g.IndexSizeBytes,
    readCapacity: g.ProvisionedThroughput?.ReadCapacityUnits || undefined,
    writeCapacity: g.ProvisionedThroughput?.WriteCapacityUnits || undefined,
  }));
  const lsis = (table.LocalSecondaryIndexes || []).map((l) => ({
    indexName: l.IndexName || '',
    indexType: 'LSI',
    keySchema: keySchemaOf(l.KeySchema),
    projectionType: l.Projection?.ProjectionType,
    nonKeyAttributes: l.Projection?.NonKeyAttributes || [],
    itemCount: l.ItemCount,
    sizeBytes: l.IndexSizeBytes,
  }));
  return [...gsis, ...lsis];
}

/** Everything the Overview / Indexes / Additional settings tabs show, in one call. */
export async function getTableDetail(profile: string, region: string, tableName: string): Promise<DdbTableDetail> {
  const client = createDdbClient(profile, region);
  const table = (await client.send(new DescribeTableCommand({ TableName: tableName }))).Table;
  if (!table) throw new Error('Table not found');
  // Secondary lookups are independent - and any one of them can be denied
  // by IAM without that hiding the rest of the page.
  const [backups, ttl, tags] = await Promise.all([
    client.send(new DescribeContinuousBackupsCommand({ TableName: tableName })).catch(() => undefined),
    client.send(new DescribeTimeToLiveCommand({ TableName: tableName })).catch(() => undefined),
    client.send(new ListTagsOfResourceCommand({ ResourceArn: table.TableArn })).catch(() => undefined),
  ]);
  const pitr = backups?.ContinuousBackupsDescription?.PointInTimeRecoveryDescription;

  return {
    tableName: table.TableName || tableName,
    tableArn: table.TableArn || '',
    tableStatus: table.TableStatus || '',
    itemCount: table.ItemCount || 0,
    tableSizeBytes: table.TableSizeBytes || 0,
    creationDateTime: table.CreationDateTime?.toISOString(),
    keySchema: keySchemaOf(table.KeySchema),
    attributeDefinitions: (table.AttributeDefinitions || []).map((a) => ({ attributeName: a.AttributeName || '', attributeType: a.AttributeType || '' })),
    billingMode: table.BillingModeSummary?.BillingMode || 'PROVISIONED',
    readCapacity: table.ProvisionedThroughput?.ReadCapacityUnits || undefined,
    writeCapacity: table.ProvisionedThroughput?.WriteCapacityUnits || undefined,
    tableClass: table.TableClassSummary?.TableClass || 'STANDARD',
    deletionProtection: table.DeletionProtectionEnabled || false,
    streamEnabled: table.StreamSpecification?.StreamEnabled || false,
    streamViewType: table.StreamSpecification?.StreamViewType,
    latestStreamArn: table.LatestStreamArn,
    encryption: table.SSEDescription?.SSEType ? `${table.SSEDescription.SSEType} (${table.SSEDescription.Status})` : 'Owned by Amazon DynamoDB',
    kmsKeyArn: table.SSEDescription?.KMSMasterKeyArn,
    pitrEnabled: pitr?.PointInTimeRecoveryStatus === 'ENABLED',
    earliestRestorableTime: pitr?.EarliestRestorableDateTime?.toISOString(),
    latestRestorableTime: pitr?.LatestRestorableDateTime?.toISOString(),
    ttlStatus: ttl?.TimeToLiveDescription?.TimeToLiveStatus || 'DISABLED',
    ttlAttribute: ttl?.TimeToLiveDescription?.AttributeName,
    replicaRegions: (table.Replicas || []).map((r) => r.RegionName || '').filter(Boolean),
    indexes: describeIndexes(table),
    tags: (tags?.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

export async function setDeletionProtection(profile: string, region: string, tableName: string, enabled: boolean): Promise<DdbTableDetail> {
  await createDdbClient(profile, region).send(new UpdateTableCommand({ TableName: tableName, DeletionProtectionEnabled: enabled }));
  return getTableDetail(profile, region, tableName);
}

export async function setPointInTimeRecovery(profile: string, region: string, tableName: string, enabled: boolean): Promise<DdbTableDetail> {
  await createDdbClient(profile, region).send(
    new UpdateContinuousBackupsCommand({ TableName: tableName, PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: enabled } })
  );
  return getTableDetail(profile, region, tableName);
}

/** DynamoDB only allows one TTL change per table per hour; that error comes back as-is. */
export async function setTimeToLive(profile: string, region: string, tableName: string, attributeName: string, enabled: boolean): Promise<DdbTableDetail> {
  await createDdbClient(profile, region).send(
    new UpdateTimeToLiveCommand({ TableName: tableName, TimeToLiveSpecification: { AttributeName: attributeName, Enabled: enabled } })
  );
  return getTableDetail(profile, region, tableName);
}

export async function addTableTag(profile: string, region: string, tableName: string, arn: string, key: string, value: string): Promise<DdbTableDetail> {
  await createDdbClient(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  return getTableDetail(profile, region, tableName);
}

export async function removeTableTag(profile: string, region: string, tableName: string, arn: string, key: string): Promise<DdbTableDetail> {
  await createDdbClient(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  return getTableDetail(profile, region, tableName);
}

export async function listBackups(profile: string, region: string, tableName: string): Promise<DdbBackup[]> {
  const client = createDdbClient(profile, region);
  const backups: DdbBackup[] = [];
  let start: string | undefined;
  do {
    const res = await client.send(new ListBackupsCommand({ TableName: tableName, ExclusiveStartBackupArn: start }));
    for (const b of res.BackupSummaries || []) {
      backups.push({
        backupArn: b.BackupArn || '',
        backupName: b.BackupName || '',
        backupStatus: b.BackupStatus,
        backupType: b.BackupType,
        createdAt: b.BackupCreationDateTime?.toISOString(),
        sizeBytes: b.BackupSizeBytes,
      });
    }
    start = res.LastEvaluatedBackupArn;
  } while (start && backups.length < 500);
  return backups.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
}

export async function createBackup(profile: string, region: string, tableName: string, backupName: string): Promise<void> {
  await createDdbClient(profile, region).send(new CreateBackupCommand({ TableName: tableName, BackupName: backupName }));
}

export async function deleteBackup(profile: string, region: string, backupArn: string): Promise<void> {
  await createDdbClient(profile, region).send(new DeleteBackupCommand({ BackupArn: backupArn }));
}

/** Last-24h single-datapoint summary - same approach as the Lambda / RDS Monitor tabs. */
export async function getTableMetrics(profile: string, region: string, tableName: string): Promise<DdbMetricsSummary> {
  const cw = new CloudWatchClient({ region, credentials: cachedCredentials(profile) });
  const end = new Date();
  const start = new Date(end.getTime() - 24 * 60 * 60 * 1000);
  const stat = async (metric: string, statistic: Statistic, operation?: string) => {
    const dims = [{ Name: 'TableName', Value: tableName }, ...(operation ? [{ Name: 'Operation', Value: operation }] : [])];
    const res = await cw.send(
      new GetMetricStatisticsCommand({ Namespace: 'AWS/DynamoDB', MetricName: metric, Dimensions: dims, StartTime: start, EndTime: end, Period: 86400, Statistics: [statistic] })
    );
    return res.Datapoints?.[0]?.[statistic];
  };
  const [rcu, wcu, rThrottle, wThrottle, getLat, queryLat, scanLat, putLat] = await Promise.all([
    stat('ConsumedReadCapacityUnits', 'Sum'),
    stat('ConsumedWriteCapacityUnits', 'Sum'),
    stat('ReadThrottleEvents', 'Sum'),
    stat('WriteThrottleEvents', 'Sum'),
    stat('SuccessfulRequestLatency', 'Average', 'GetItem'),
    stat('SuccessfulRequestLatency', 'Average', 'Query'),
    stat('SuccessfulRequestLatency', 'Average', 'Scan'),
    stat('SuccessfulRequestLatency', 'Average', 'PutItem'),
  ]);
  return {
    consumedReadCapacity: rcu,
    consumedWriteCapacity: wcu,
    readThrottleEvents: rThrottle,
    writeThrottleEvents: wThrottle,
    getItemLatencyMs: getLat,
    queryLatencyMs: queryLat,
    scanLatencyMs: scanLat,
    putItemLatencyMs: putLat,
  };
}

function keyValue(type: string, value: string, label: string): AttributeValue {
  if (type === 'N') {
    if (value.trim() === '' || Number.isNaN(Number(value))) throw badRequest(`${label} must be a number`);
    return { N: value.trim() };
  }
  if (type === 'B') return { B: Buffer.from(value, 'base64') };
  return { S: value };
}

const SORT_OPERATORS: Record<string, (sk: string) => string> = {
  '=': (sk) => `${sk} = :sk1`,
  '<': (sk) => `${sk} < :sk1`,
  '<=': (sk) => `${sk} <= :sk1`,
  '>': (sk) => `${sk} > :sk1`,
  '>=': (sk) => `${sk} >= :sk1`,
  between: (sk) => `${sk} BETWEEN :sk1 AND :sk2`,
  begins_with: (sk) => `begins_with(${sk}, :sk1)`,
};

/**
 * The console's "Query" (Explore items): partition key equality plus an
 * optional sort-key condition, on the table or one of its indexes - reads
 * only the matching partition instead of scanning the table.
 */
const QUERY_CALL_BUDGET_MS = 3_000;

export async function queryTable(profile: string, region: string, tableName: string, req: DdbQueryRequest): Promise<DdbPageResult> {
  if (!req.partitionKey?.name) throw badRequest('partitionKey is required');
  const names: Record<string, string> = { '#pk': req.partitionKey.name };
  const values: Record<string, AttributeValue> = { ':pk': keyValue(req.partitionKey.type, req.partitionKey.value, req.partitionKey.name) };
  let condition = '#pk = :pk';
  if (req.sortKey && req.sortKey.operator && req.sortKey.operator !== 'none') {
    const build = SORT_OPERATORS[req.sortKey.operator];
    if (!build) throw badRequest(`Unknown sort key operator ${req.sortKey.operator}`);
    if (req.sortKey.operator === 'begins_with' && req.sortKey.type === 'N') throw badRequest('begins_with does not work on a Number sort key');
    names['#sk'] = req.sortKey.name;
    values[':sk1'] = keyValue(req.sortKey.type, req.sortKey.value, req.sortKey.name);
    if (req.sortKey.operator === 'between') values[':sk2'] = keyValue(req.sortKey.type, req.sortKey.value2 ?? '', req.sortKey.name);
    condition += ` AND ${build('#sk')}`;
  }
  // Like `aws dynamodb query`: no per-request Limit, so every call reads a
  // full 1 MB page of the partition. A small Limit (the console uses 50)
  // turns one partition into dozens of round trips - and with a filter,
  // most of those pages come back with few or no matches. Pages are read
  // back to back until `limit` matches, the time budget, or the end of the
  // partition; whole pages are consumed, so LastEvaluatedKey is the cursor.
  const conditions = req.conditions ?? [];
  const target = Math.min(Math.max(req.limit || 100, 1), 5_000);
  const deadline = Date.now() + QUERY_CALL_BUDGET_MS;
  const client = createDdbClient(profile, region);
  const items: Record<string, any>[] = [];
  let scannedCount = 0;
  let startKey: Record<string, AttributeValue> | undefined = req.startKey ? marshall(req.startKey) : undefined;
  do {
    const res = await client.send(
      new QueryCommand({
        TableName: tableName,
        IndexName: req.indexName || undefined,
        KeyConditionExpression: condition,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
        ScanIndexForward: req.ascending,
        ExclusiveStartKey: startKey,
      })
    );
    for (const raw of res.Items || []) {
      scannedCount++;
      const item = unmarshallPlain(raw);
      // Same case-insensitive Filter Builder rules as the whole-table search.
      if (matchesAll(conditions, item)) items.push(item);
    }
    startKey = res.LastEvaluatedKey;
  } while (startKey && items.length < target && Date.now() < deadline);
  return {
    items,
    scannedCount,
    lastEvaluatedKey: startKey ? unmarshallPlain(startKey) : undefined,
  };
}

/** PartiQL editor. Write statements (INSERT/UPDATE/DELETE) are allowed - the UI asks first. */
export async function executePartiQL(profile: string, region: string, statement: string, nextToken?: string, limit = 1_000): Promise<DdbPageResult> {
  if (!statement.trim()) throw badRequest('statement is required');
  // No `Limit`: on ExecuteStatement it caps items *evaluated*, not
  // returned, so a WHERE on a non-key attribute (a filtered scan) used to
  // come back with an empty page + NextToken and look like "no results".
  // Read 1 MB pages back to back instead until `limit` rows (the app asks
  // for 100 at a time - Load More / Load All), the time budget, or the
  // end. Pages are consumed whole, so a call can return more than `limit`;
  // the app keeps the extra rows and shows them on the next Load More.
  const client = createDdbClient(profile, region);
  const deadline = Date.now() + QUERY_CALL_BUDGET_MS;
  const items: Record<string, any>[] = [];
  let token = nextToken || undefined;
  do {
    const res = await client.send(new ExecuteStatementCommand({ Statement: statement, NextToken: token }));
    items.push(...(res.Items || []).map(unmarshallPlain));
    token = res.NextToken;
  } while (token && items.length < limit && Date.now() < deadline);
  return { items, nextToken: token };
}

export async function createTable(
  profile: string,
  region: string,
  input: { tableName: string; partitionKey: { name: string; type: string }; sortKey?: { name: string; type: string } }
): Promise<DdbTableDetail> {
  const keys = [input.partitionKey, ...(input.sortKey?.name ? [input.sortKey] : [])];
  for (const k of keys) {
    if (!k.name?.trim()) throw badRequest('Key attribute names are required');
    if (!['S', 'N', 'B'].includes(k.type)) throw badRequest('Key types must be S, N or B');
  }
  await createDdbClient(profile, region).send(
    new CreateTableCommand({
      TableName: input.tableName,
      // On-demand: no capacity to size up front - same default the console now uses.
      BillingMode: 'PAY_PER_REQUEST',
      AttributeDefinitions: keys.map((k) => ({ AttributeName: k.name, AttributeType: k.type as ScalarAttributeType })),
      KeySchema: [
        { AttributeName: input.partitionKey.name, KeyType: 'HASH' },
        ...(input.sortKey?.name ? [{ AttributeName: input.sortKey.name, KeyType: 'RANGE' as const }] : []),
      ],
    })
  );
  return getTableDetail(profile, region, input.tableName);
}

/** Fails (from AWS) while deletion protection is on - the UI says so. */
export async function deleteTable(profile: string, region: string, tableName: string): Promise<void> {
  await createDdbClient(profile, region).send(new DeleteTableCommand({ TableName: tableName }));
}
