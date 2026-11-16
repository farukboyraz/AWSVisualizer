import {
  DynamoDBClient,
  ListTablesCommand,
  DescribeTableCommand,
  ScanCommand,
  QueryCommand,
  BatchGetItemCommand,
  PutItemCommand,
  DeleteItemCommand,
  GetItemCommand,
  type AttributeValue,
  type TableDescription,
} from '@aws-sdk/client-dynamodb';
import { unmarshall, marshall } from '@aws-sdk/util-dynamodb';
import { cachedCredentials } from './credential-cache.js';
import { describeIndexes } from './dynamodb-table.js';
import type { DdbTableInfo, DdbScanResult, DdbFilterCondition, DdbSearchResult } from '../../domain/entities/index.js';

export function createDdbClient(profile: string, region: string): DynamoDBClient {
  return new DynamoDBClient({
    region,
    credentials: cachedCredentials(profile),
  });
}

/**
 * `unmarshall()` output made JSON-safe. Without this, string/number sets
 * (`SS`/`NS`) are JS `Set`s that `JSON.stringify` writes as `{}` (so a set
 * attribute showed up empty in the item viewer), binary comes out as a
 * `Uint8Array` keyed "0","1",..., and a number beyond 2^53 is a `BigInt`
 * that makes `JSON.stringify` throw - failing the whole scan response.
 */
function toPlain(value: unknown): unknown {
  if (value instanceof Set) return Array.from(value, toPlain);
  if (value instanceof Uint8Array) return Buffer.from(value).toString('base64');
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map(toPlain);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, toPlain(v)]));
  }
  return value;
}

export function unmarshallPlain(item: Record<string, AttributeValue>): Record<string, any> {
  return toPlain(unmarshall(item, { wrapNumbers: false })) as Record<string, any>;
}

/**
 * DynamoDB JSON ({"S": ...}, {"SS": [...]}, ...) made JSON-safe for the
 * client: binary (`B`/`BS`) as base64 strings - `fromTypedJson` reverses it.
 */
function toTypedJson(value: AttributeValue): Record<string, unknown> {
  if (value.B !== undefined) return { B: Buffer.from(value.B).toString('base64') };
  if (value.BS !== undefined) return { BS: value.BS.map((b) => Buffer.from(b).toString('base64')) };
  if (value.M !== undefined) return { M: Object.fromEntries(Object.entries(value.M).map(([k, v]) => [k, toTypedJson(v)])) };
  if (value.L !== undefined) return { L: value.L.map(toTypedJson) };
  // S, N, BOOL, NULL, SS, NS are already plain JSON.
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined));
}

const TYPE_KEYS = ['S', 'N', 'B', 'BOOL', 'NULL', 'M', 'L', 'SS', 'NS', 'BS'];

function fromTypedJson(value: unknown, path: string): AttributeValue {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw badRequest(`${path}: expected an object like {"S": "..."}`);
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length !== 1 || !TYPE_KEYS.includes(entries[0][0])) {
    throw badRequest(`${path}: must have exactly one type key (${TYPE_KEYS.join(', ')})`);
  }
  const [type, v] = entries[0];
  switch (type) {
    case 'B':
      return { B: Buffer.from(String(v), 'base64') };
    case 'BS':
      return { BS: (v as unknown[]).map((b) => Buffer.from(String(b), 'base64')) };
    case 'M':
      return { M: Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, fromTypedJson(x, `${path}.${k}`)])) };
    case 'L':
      return { L: (v as unknown[]).map((x, i) => fromTypedJson(x, `${path}[${i}]`)) };
    default:
      return { [type]: v } as unknown as AttributeValue;
  }
}

function badRequest(message: string): Error {
  return Object.assign(new Error(message), { name: 'ValidationException', $metadata: { httpStatusCode: 400 } });
}

export async function listTables(profile: string, region: string): Promise<string[]> {
  const client = createDdbClient(profile, region);
  const command = new ListTablesCommand({});
  const response = await client.send(command);
  return response.TableNames || [];
}

export async function describeTable(
  profile: string,
  region: string,
  tableName: string
): Promise<DdbTableInfo> {
  const client = createDdbClient(profile, region);
  const command = new DescribeTableCommand({ TableName: tableName });
  const response = await client.send(command);
  const table = response.Table!;

  return {
    tableName: table.TableName || '',
    tableStatus: table.TableStatus || '',
    itemCount: table.ItemCount || 0,
    tableSizeBytes: table.TableSizeBytes || 0,
    creationDateTime: table.CreationDateTime?.toISOString(),
    keySchema: (table.KeySchema || []).map((ks) => ({
      attributeName: ks.AttributeName || '',
      keyType: ks.KeyType || '',
    })),
    attributeDefinitions: (table.AttributeDefinitions || []).map((ad) => ({
      attributeName: ad.AttributeName || '',
      attributeType: ad.AttributeType || '',
    })),
    indexes: describeIndexes(table),
  };
}

export async function scanTable(
  profile: string,
  region: string,
  tableName: string,
  limit?: number,
  startKey?: Record<string, any>
): Promise<DdbScanResult> {
  const client = createDdbClient(profile, region);

  const command = new ScanCommand({
    TableName: tableName,
    Limit: limit || 25,
    // `startKey` arrives as plain unmarshalled values (same shape `deleteItem`
    // takes before its own `marshall()` call) - the low-level ScanCommand
    // needs DynamoDB's `{ S: ... } / { N: ... }` wire format here, not a
    // plain JS object. Passing it unmarshalled doesn't throw a validation
    // error, it throws deep inside the SDK's own serializer instead
    // ("Cannot read properties of undefined (reading '0')"), which is what
    // made page 2 of any paginated scan fail outright.
    ExclusiveStartKey: startKey ? marshall(startKey) : undefined,
  });

  const response = await client.send(command);
  const items = (response.Items || []).map(unmarshallPlain);

  return {
    items,
    count: response.Count || 0,
    scannedCount: response.ScannedCount || 0,
    lastEvaluatedKey: response.LastEvaluatedKey
      ? unmarshallPlain(response.LastEvaluatedKey)
      : undefined,
  };
}

/**
 * PutItem replaces the whole item, so this covers both "create a new item"
 * and "edit an existing item" - same as the DynamoDB console's item editor.
 */
export async function putItem(profile: string, region: string, tableName: string, item: Record<string, unknown>): Promise<void> {
  const client = createDdbClient(profile, region);
  await client.send(new PutItemCommand({ TableName: tableName, Item: marshall(item, { removeUndefinedValues: true }) }));
}

export async function deleteItem(profile: string, region: string, tableName: string, key: Record<string, unknown>): Promise<void> {
  const client = createDdbClient(profile, region);
  await client.send(new DeleteItemCommand({ TableName: tableName, Key: marshall(key) }));
}

// ---------------------------------------------------------------------------
// Whole-table search for the Filter Builder.
//
// The Filter Builder used to filter only the 25 rows on screen, so anything
// past page 1 was invisible to it. This walks the whole table with Scan and
// applies the *same* matching rules the Swift side uses (ColumnFilter.swift)
// to each item's display text - case-insensitive Equal/Contain/In, BNN, and
// a flat left-to-right AND/OR fold - so results are identical to what the
// on-screen filter would have shown had every item been on one page.
//
// Deliberately not a DynamoDB FilterExpression: that is case-sensitive and
// type-sensitive (the string "5" ≠ the number 5), and applies AND before OR,
// none of which match the builder's semantics - and it wouldn't save any
// read capacity either (a filtered Scan still reads every item).
// ---------------------------------------------------------------------------

/** Mirrors Swift `DdbValue.displayString` - the text a cell shows and the filter matches against. */
function displayString(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (value === null) return 'null';
  if (typeof value === 'string') return value;
  if (typeof value === 'number') {
    // Swift prints whole numbers below 1e15 as integers ("12", not
    // "12.0"); JS already does, so plain String() matches either way.
    return String(value);
  }
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (value instanceof Set) return `[${value.size} items]`;
  if (Array.isArray(value)) return `[${value.length} items]`;
  if (value instanceof Uint8Array) return `[${value.length} bytes]`;
  if (typeof value === 'object') return `{${Object.keys(value as object).length} keys}`;
  return String(value);
}

function isBlankNullNone(raw: string | undefined): boolean {
  if (raw === undefined) return true;
  const trimmed = raw.trim().toLowerCase();
  return trimmed === '' || trimmed === 'null' || trimmed === 'none';
}

function matchesSingle(condition: DdbFilterCondition, raw: string | undefined): boolean {
  const first = (condition.values[0] ?? '').toLowerCase();
  switch (condition.matchOperator) {
    case 'onlyBNN':
      return isBlankNullNone(raw);
    case 'notBNN':
      return !isBlankNullNone(raw);
    case 'equal':
      return raw !== undefined && raw.toLowerCase() === first;
    case 'notEqual':
      return raw === undefined || raw.toLowerCase() !== first;
    case 'contains':
      if (first === '') return true;
      return raw !== undefined && raw.toLowerCase().includes(first);
    case 'in': {
      const candidates = condition.values.filter((v) => v !== '').map((v) => v.toLowerCase());
      if (candidates.length === 0) return true;
      return raw !== undefined && candidates.includes(raw.toLowerCase());
    }
    default:
      return false;
  }
}

export function matchesAll(conditions: DdbFilterCondition[], item: Record<string, unknown>): boolean {
  if (conditions.length === 0) return true;
  let result = matchesSingle(conditions[0], displayString(item[conditions[0].columnID]));
  for (const condition of conditions.slice(1)) {
    const current = matchesSingle(condition, displayString(item[condition.columnID]));
    result = condition.logicalOperator === 'or' ? result || current : result && current;
  }
  return result;
}

/**
 * Resume state of a parallel scan: one ExclusiveStartKey per segment
 * (`null` = segment not started yet, `"done"` = segment exhausted).
 * Serialized as base64 JSON so the client treats it as an opaque token.
 * `query` is set while the search reads one partition instead (see
 * `pickKeyRoute`); `segments` then only matter if it falls back to a scan.
 */
interface SearchCursor {
  totalSegments: number;
  segments: (Record<string, AttributeValue> | null | 'done')[];
  query?: KeyRoute & { startKey?: Record<string, AttributeValue>; read: number };
  /** The table's key attributes - lets the scan fetch keys + filtered columns only (see `searchTable`). */
  keyNames?: string[];
}

function encodeCursor(cursor: SearchCursor): string | undefined {
  if (!cursor.query && cursor.segments.every((s) => s === 'done')) return undefined;
  return Buffer.from(JSON.stringify(cursor)).toString('base64');
}

function decodeCursor(token: string): SearchCursor {
  try {
    const parsed = JSON.parse(Buffer.from(token, 'base64').toString('utf8')) as SearchCursor;
    if (!Number.isInteger(parsed.totalSegments) || !Array.isArray(parsed.segments) || parsed.segments.length !== parsed.totalSegments) throw new Error();
    return parsed;
  } catch {
    throw Object.assign(new Error('Invalid search cursor'), { name: 'ValidationException', $metadata: { httpStatusCode: 400 } });
  }
}

/**
 * How many segments to scan in parallel. Parallelism only pays off once
 * there are several 1 MB pages to read; on a provisioned table it's kept
 * low because each segment burns read capacity at the same time and a
 * low-RCU table would just start throttling (the SDK then backs off and
 * retries, which is *slower* than reading sequentially).
 */
function chooseSegments(sizeBytes: number, billingMode: string | undefined): number {
  const MB = 1024 * 1024;
  let segments = sizeBytes < 4 * MB ? 1 : sizeBytes < 32 * MB ? 4 : sizeBytes < 256 * MB ? 8 : 16;
  if (billingMode !== 'PAY_PER_REQUEST') segments = Math.min(segments, 2);
  return segments;
}

/**
 * A partition the search can Query instead of scanning the whole table.
 * When the conditions require `PK = x` (or `GSI1PK = x`, `GSI2PK = x`, ...
 * on an index) - an `equal` that every other condition is ANDed with, so
 * no OR can bring in items from other partitions - only that partition
 * can match, and reading it is what `aws dynamodb query` does: milliseconds
 * instead of a full scan. Every condition is still applied to what the
 * Query returns, so the result is the same as the scan's.
 */
interface KeyRoute {
  indexName?: string;
  attribute: string;
  type: 'S' | 'N';
  value: string;
  /** Sort key equality (`SK = y`, `GSI1SK = y`) on the same table/index - narrows the Query further. */
  sortKey?: { attribute: string; type: 'S' | 'N'; value: string };
}

export function pickKeyRoute(table: TableDescription | undefined, conditions: DdbFilterCondition[]): KeyRoute | undefined {
  if (!table) return undefined;
  const required = new Map<string, string>();
  conditions.forEach((c, i) => {
    // The builder folds left to right: ((a OR b) AND c). A condition is a
    // top-level AND term only if neither it nor anything after it is an OR.
    const andTerm = (i === 0 || c.logicalOperator !== 'or') && conditions.slice(i + 1).every((n) => n.logicalOperator !== 'or');
    if (andTerm && c.matchOperator === 'equal' && c.values[0]) required.set(c.columnID, c.values[0]);
  });
  if (required.size === 0) return undefined;
  const typeOf = (name: string) => table.AttributeDefinitions?.find((a) => a.AttributeName === name)?.AttributeType;
  const candidates = [
    { indexName: undefined as string | undefined, keySchema: table.KeySchema },
    // Only indexes that project every attribute - a KEYS_ONLY / INCLUDE
    // index would return items missing the attributes the grid shows.
    ...(table.GlobalSecondaryIndexes || [])
      .filter((g) => g.Projection?.ProjectionType === 'ALL' && (!g.IndexStatus || g.IndexStatus === 'ACTIVE'))
      .map((g) => ({ indexName: g.IndexName, keySchema: g.KeySchema })),
  ];
  const keyPart = (attribute: string | undefined) => {
    const value = attribute ? required.get(attribute) : undefined;
    const type = attribute ? typeOf(attribute) : undefined;
    if (!attribute || value === undefined) return undefined;
    if (type === 'S') return { attribute, type: 'S' as const, value };
    if (type === 'N' && value.trim() !== '' && !Number.isNaN(Number(value))) return { attribute, type: 'N' as const, value: value.trim() };
    return undefined;
  };
  const routes: KeyRoute[] = [];
  for (const { indexName, keySchema } of candidates) {
    const hash = keyPart(keySchema?.find((k) => k.KeyType === 'HASH')?.AttributeName);
    if (!hash) continue;
    const sortKey = keyPart(keySchema?.find((k) => k.KeyType === 'RANGE')?.AttributeName);
    routes.push({ indexName, ...hash, sortKey });
  }
  // Partition + sort key beats partition alone (`PK = x AND SK = y` is a
  // single item); otherwise the table first, then the indexes in order.
  return routes.find((r) => r.sortKey) ?? routes[0];
}

/**
 * Whole-table Filter Builder search, built for streaming results:
 * - **Query when possible** - conditions that pin a partition key (see
 *   `pickKeyRoute`) read just that partition. Key values are matched
 *   exactly by DynamoDB while the builder ignores case, so if the exact
 *   value has no items at all (e.g. typed `user#all` for `USER#ALL`) the
 *   search falls back to the scan below.
 * - **Parallel scan** (`Segment` / `TotalSegments`) - several 1 MB pages
 *   are read at once instead of strictly one after another.
 * - **Short calls** - each call returns after ~`SEARCH_CALL_BUDGET_MS`
 *   with whatever it found (or as soon as `maxResults` is reached), plus a
 *   cursor. The client keeps calling while it wants more, so matches
 *   appear within seconds instead of after a 20 s wait, and nothing has to
 *   be confirmed with a "Keep searching" click.
 * Pages are always consumed whole, so the cursor is simply each segment's
 * (or the Query's) LastEvaluatedKey - no mid-page resume bookkeeping. A
 * call can therefore return a few more than `maxResults` matches.
 */
const SEARCH_CALL_BUDGET_MS = 3_000;

export async function searchTable(
  profile: string,
  region: string,
  tableName: string,
  conditions: DdbFilterCondition[],
  maxResults: number,
  cursorToken?: string
): Promise<DdbSearchResult> {
  const client = createDdbClient(profile, region);
  const deadline = Date.now() + SEARCH_CALL_BUDGET_MS;

  let cursor: SearchCursor;
  if (cursorToken) {
    cursor = decodeCursor(cursorToken);
  } else {
    const table = (await client.send(new DescribeTableCommand({ TableName: tableName }))).Table;
    const totalSegments = chooseSegments(table?.TableSizeBytes || 0, table?.BillingModeSummary?.BillingMode);
    cursor = { totalSegments, segments: Array(totalSegments).fill(null) };
    const keyNames = (table?.KeySchema || []).map((k) => k.AttributeName || '').filter(Boolean);
    if (keyNames.length) cursor.keyNames = keyNames;
    const route = pickKeyRoute(table, conditions);
    if (route) cursor.query = { ...route, read: 0 };
  }

  const items: Record<string, any>[] = [];
  let scannedCount = 0;
  let route: DdbSearchResult['route'];

  if (cursor.query) {
    const q = cursor.query;
    route = { indexName: q.indexName, attribute: q.attribute, value: q.value, sortKey: q.sortKey && { attribute: q.sortKey.attribute, value: q.sortKey.value } };
    let more = true;
    while (more) {
      const page = await client.send(
        new QueryCommand({
          TableName: tableName,
          IndexName: q.indexName,
          KeyConditionExpression: q.sortKey ? '#pk = :pk AND #sk = :sk' : '#pk = :pk',
          ExpressionAttributeNames: { '#pk': q.attribute, ...(q.sortKey ? { '#sk': q.sortKey.attribute } : {}) },
          ExpressionAttributeValues: {
            ':pk': q.type === 'N' ? { N: q.value } : { S: q.value },
            ...(q.sortKey ? { ':sk': q.sortKey.type === 'N' ? { N: q.sortKey.value } : { S: q.sortKey.value } } : {}),
          },
          ExclusiveStartKey: q.startKey,
        })
      );
      for (const raw of page.Items || []) {
        scannedCount++;
        const item = unmarshallPlain(raw);
        if (matchesAll(conditions, item)) items.push(item);
      }
      q.read += page.Items?.length || 0;
      q.startKey = page.LastEvaluatedKey;
      more = !!q.startKey && items.length < maxResults && Date.now() < deadline;
    }
    if (q.startKey) {
      return { items, scannedCount, cursor: encodeCursor(cursor), totalSegments: 1, route };
    }
    if (q.read > 0) {
      return { items, scannedCount, cursor: undefined, totalSegments: 1, route };
    }
    // Nothing stored under that exact key - maybe a case difference the
    // builder would forgive. Scan the table like before.
    cursor.query = undefined;
    route = undefined;
  }

  // Scan only the keys + the attributes the conditions look at. DynamoDB
  // still reads every item (that can't be avoided for `contains`, `<>`…,
  // or a key condition it can't Query), but a page then carries a few
  // bytes per item instead of whole items - transferring and parsing
  // 1 MB pages, several segments at once, is most of a slow search. The
  // matches are then fetched whole with BatchGetItem.
  const keyNames = cursor.keyNames;
  const projected = !!keyNames?.length;
  const names: Record<string, string> = {};
  if (projected) {
    [...new Set([...keyNames!, ...conditions.map((c) => c.columnID)])].forEach((name, i) => (names[`#p${i}`] = name));
  }

  // Rounds: every unfinished segment reads one page concurrently; repeat
  // until enough matches, the call's time budget, or the end of the table.
  while (cursor.segments.some((s) => s !== 'done') && items.length < maxResults && Date.now() < deadline) {
    const active = cursor.segments
      .map((position, segment) => ({ position, segment }))
      .filter((s) => s.position !== 'done');

    const pages = await Promise.all(
      active.map(({ position, segment }) =>
        client.send(
          new ScanCommand({
            TableName: tableName,
            Segment: cursor.totalSegments > 1 ? segment : undefined,
            TotalSegments: cursor.totalSegments > 1 ? cursor.totalSegments : undefined,
            ExclusiveStartKey: position && position !== 'done' ? position : undefined,
            ProjectionExpression: projected ? Object.keys(names).join(', ') : undefined,
            ExpressionAttributeNames: projected ? names : undefined,
          })
        )
      )
    );

    const matchedKeys: Record<string, AttributeValue>[] = [];
    pages.forEach((page, i) => {
      for (const raw of page.Items || []) {
        scannedCount++;
        if (!matchesAll(conditions, unmarshallPlain(raw))) continue;
        if (projected) {
          matchedKeys.push(Object.fromEntries(keyNames!.map((k) => [k, raw[k]])));
        } else {
          items.push(unmarshallPlain(raw));
        }
      }
      cursor.segments[active[i].segment] = page.LastEvaluatedKey ?? 'done';
    });
    if (matchedKeys.length) {
      // Re-checked on the full item in case it changed in between.
      for (const item of await batchGetItems(client, tableName, keyNames!, matchedKeys)) {
        if (matchesAll(conditions, item)) items.push(item);
      }
    }
  }

  return { items, scannedCount, cursor: encodeCursor(cursor), totalSegments: cursor.totalSegments };
}

/** Full items for `keys` (any count), in the same order; missing ones are skipped. */
async function batchGetItems(
  client: DynamoDBClient,
  tableName: string,
  keyNames: string[],
  keys: Record<string, AttributeValue>[]
): Promise<Record<string, any>[]> {
  const id = (item: Record<string, AttributeValue>) => JSON.stringify(keyNames.map((k) => item[k]));
  const found = new Map<string, Record<string, AttributeValue>>();
  const chunks: Record<string, AttributeValue>[][] = [];
  for (let i = 0; i < keys.length; i += 100) chunks.push(keys.slice(i, i + 100));
  await Promise.all(
    chunks.map(async (chunk) => {
      let pending = chunk;
      // Unprocessed keys (throttling) are retried with a short backoff.
      for (let attempt = 0; pending.length && attempt < 8; attempt++) {
        if (attempt) await new Promise((r) => setTimeout(r, 50 * 2 ** attempt));
        const res = await client.send(new BatchGetItemCommand({ RequestItems: { [tableName]: { Keys: pending } } }));
        for (const raw of res.Responses?.[tableName] || []) found.set(id(raw), raw);
        pending = (res.UnprocessedKeys?.[tableName]?.Keys as Record<string, AttributeValue>[] | undefined) || [];
      }
    })
  );
  return keys.flatMap((k) => {
    const raw = found.get(id(k));
    return raw ? [unmarshallPlain(raw)] : [];
  });
}

/**
 * The item exactly as DynamoDB stores it (typed "DynamoDB JSON"), for the
 * item sheet's DynamoDB JSON and Form views - the plain JSON the grid uses
 * can't tell a string set from a list, or the number 5 from the string "5".
 */
export async function getItemTyped(profile: string, region: string, tableName: string, key: Record<string, unknown>): Promise<{ item?: Record<string, unknown> }> {
  const client = createDdbClient(profile, region);
  const res = await client.send(new GetItemCommand({ TableName: tableName, Key: marshall(key), ConsistentRead: true }));
  if (!res.Item) return {};
  return { item: Object.fromEntries(Object.entries(res.Item).map(([k, v]) => [k, toTypedJson(v)])) };
}

/** PutItem from typed DynamoDB JSON - keeps every attribute's exact type (sets, numbers, binary). */
export async function putItemTyped(profile: string, region: string, tableName: string, item: Record<string, unknown>): Promise<void> {
  if (!item || typeof item !== 'object' || Array.isArray(item)) throw badRequest('item must be an object');
  const marshalled = Object.fromEntries(Object.entries(item).map(([k, v]) => [k, fromTypedJson(v, k)]));
  const client = createDdbClient(profile, region);
  await client.send(new PutItemCommand({ TableName: tableName, Item: marshalled }));
}

// ---- Attribute names for the Filter Builder

/** Pages (≤ 1 MB each) and time spent collecting names, and how long they are kept. */
const ATTRIBUTE_SCAN_PAGES = 5;
const ATTRIBUTE_SCAN_BUDGET_MS = 4_000;
const ATTRIBUTE_CACHE_MS = 10 * 60_000;
const attributeCache = new Map<string, { at: number; names: string[]; complete: boolean }>();

/**
 * Every attribute name of a table the Filter Builder can offer. DynamoDB
 * has no schema beyond its keys, so a sparse attribute (only on some
 * items) is missing from whatever page is on screen - that's why it
 * couldn't be picked. This reads the key / index attributes plus up to 5
 * scan pages (or 4 s), keeps only the names, and caches them for 10
 * minutes. `complete` = the whole table was read.
 */
export async function getTableAttributeNames(profile: string, region: string, tableName: string): Promise<{ names: string[]; complete: boolean }> {
  const key = `${profile}|${region}|${tableName}`;
  const hit = attributeCache.get(key);
  if (hit && Date.now() - hit.at < ATTRIBUTE_CACHE_MS) return { names: hit.names, complete: hit.complete };

  const client = createDdbClient(profile, region);
  const table = (await client.send(new DescribeTableCommand({ TableName: tableName }))).Table;
  const names = new Set<string>((table?.AttributeDefinitions || []).map((a) => a.AttributeName || '').filter(Boolean));
  const deadline = Date.now() + ATTRIBUTE_SCAN_BUDGET_MS;
  let startKey: Record<string, AttributeValue> | undefined;
  let pages = 0;
  do {
    const res = await client.send(new ScanCommand({ TableName: tableName, ExclusiveStartKey: startKey }));
    for (const item of res.Items || []) for (const name of Object.keys(item)) names.add(name);
    startKey = res.LastEvaluatedKey;
    pages++;
  } while (startKey && pages < ATTRIBUTE_SCAN_PAGES && Date.now() < deadline);

  const sorted = [...names].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base', numeric: true }));
  attributeCache.set(key, { at: Date.now(), names: sorted, complete: !startKey });
  return { names: sorted, complete: !startKey };
}
