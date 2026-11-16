import { DescribeTableCommand, ScanCommand } from '@aws-sdk/client-dynamodb';
import { createDdbClient, getTableAttributeNames, listTables, searchTable, unmarshallPlain } from '../aws/dynamodb.js';
import { executePartiQL, queryTable } from '../aws/dynamodb-table.js';
import type { DdbFilterCondition, DdbQueryRequest } from '../../domain/entities/index.js';
import { t, type ServiceCards, type CardContext, type Preview, type Text, CardInputError } from './types.js';

/**
 * DynamoDB cards.
 *
 * **Search** - the main one: a search built exactly like on the DynamoDB
 * screen, in one of its three ways:
 * - `query`:   key condition on the table or an index (+ Filter Builder conditions)
 * - `scan`:    Filter Builder conditions over the whole table (the grid's search)
 * - `partiql`: a PartiQL SELECT statement
 * The card shows how many items the search returns; its Run button opens
 * the table on the DynamoDB screen and runs the same search there.
 *
 * The `search` param is JSON:
 *   { mode: 'query' | 'scan' | 'partiql',
 *     index?, pk?: { name, type, value }, sk?: { name, type, operator, value, value2? },
 *     conditions?: DdbFilterCondition[],   // Filter Builder rows, at most 5
 *     statement?: string }                 // partiql
 */

const TABLE_PATTERN = '^[A-Za-z0-9_.-]{3,255}$';
const SORT_OPERATORS = ['none', '=', '<', '<=', '>', '>=', 'begins_with', 'between'];
const MATCH_OPERATORS = ['equal', 'notEqual', 'contains', 'onlyBNN', 'notBNN', 'in'];
/** Calls (each reading up to its time budget) before a count stops and says "at least". */
const MAX_COUNT_CALLS = 20;
const PREVIEW_ROWS = 20;

export interface DynamoCardSearch {
  mode: 'query' | 'scan' | 'partiql';
  index?: string;
  pk?: { name: string; type: string; value: string };
  sk?: { name: string; type: string; operator: string; value: string; value2?: string };
  conditions: DdbFilterCondition[];
  statement?: string;
}

function tableOf(ctx: CardContext): string {
  const table = ctx.params.table || '';
  if (!new RegExp(TABLE_PATTERN).test(table)) throw new CardInputError(t('Choose a table', 'Bir tablo seç'));
  return table;
}

function checkConditions(raw: unknown): DdbFilterCondition[] {
  const conditions: DdbFilterCondition[] = Array.isArray(raw) ? raw : [];
  if (conditions.length > 5) throw new CardInputError(t('At most 5 filter conditions', 'En fazla 5 filtre koşulu'));
  for (const c of conditions) {
    if (!c || typeof c.columnID !== 'string' || !c.columnID || !MATCH_OPERATORS.includes(c.matchOperator) || !Array.isArray(c.values)) {
      throw new CardInputError(t('A filter condition is incomplete', 'Bir filtre koşulu eksik'));
    }
  }
  return conditions;
}

/** Only reads: a single SELECT, no other statement types. */
function checkStatement(statement: unknown): string {
  const text = typeof statement === 'string' ? statement.trim().replace(/;\s*$/, '') : '';
  if (!text) throw new CardInputError(t('Write the PartiQL statement', 'PartiQL ifadesini yaz'));
  if (!/^select\s/i.test(text)) throw new CardInputError(t('Only SELECT statements can be used on a card', 'Kartta yalnızca SELECT ifadeleri kullanılabilir'));
  if (text.includes(';')) throw new CardInputError(t('One statement only', 'Yalnızca tek bir ifade'));
  return text;
}

/** Parses and checks the search JSON; the messages name what is missing. */
export function parseSearch(raw: string | undefined): DynamoCardSearch {
  let q: any;
  try {
    q = JSON.parse(raw || '');
  } catch {
    throw new CardInputError(t('Set up the search', 'Aramayı oluştur'));
  }
  const mode = q?.mode === 'scan' || q?.mode === 'partiql' ? q.mode : 'query';
  if (mode === 'partiql') return { mode, conditions: [], statement: checkStatement(q.statement) };
  const conditions = checkConditions(q.conditions);
  if (mode === 'scan') {
    if (!conditions.length) throw new CardInputError(t('Add at least one filter condition', 'En az bir filtre koşulu ekle'));
    return { mode, conditions };
  }
  if (!q?.pk?.name || typeof q.pk.name !== 'string') throw new CardInputError(t('Pick the table or index to query', 'Sorgulanacak tabloyu ya da index\'i seç'));
  if (typeof q.pk.value !== 'string' || !q.pk.value) throw new CardInputError(t(`Enter a value for the partition key ${q.pk.name}`, `${q.pk.name} partition key için bir değer gir`));
  if (q.pk.type === 'N' && !/^-?\d+(\.\d+)?$/.test(q.pk.value.trim())) throw new CardInputError(t(`${q.pk.name} is a number key`, `${q.pk.name} sayı tipinde bir anahtar`));
  if (q.sk && q.sk.operator !== 'none') {
    if (!SORT_OPERATORS.includes(q.sk.operator)) throw new CardInputError(t('Unknown sort key condition', 'Bilinmeyen sort key koşulu'));
    if (!q.sk.value || (q.sk.operator === 'between' && !q.sk.value2)) throw new CardInputError(t(`Enter the value(s) for the sort key ${q.sk.name}`, `${q.sk.name} sort key için değer(ler)i gir`));
    if (q.sk.operator === 'begins_with' && q.sk.type === 'N') throw new CardInputError(t('"Begins with" only works on string sort keys', '"İle başlar" yalnızca metin sort key\'lerinde çalışır'));
  }
  return {
    mode,
    index: typeof q.index === 'string' && q.index ? q.index : undefined,
    pk: { name: q.pk.name, type: q.pk.type === 'N' ? 'N' : 'S', value: q.pk.value },
    sk: q.sk && q.sk.operator !== 'none' ? { name: q.sk.name, type: q.sk.type === 'N' ? 'N' : 'S', operator: q.sk.operator, value: q.sk.value, value2: q.sk.value2 } : undefined,
    conditions,
  };
}

const queryRequest = (s: DynamoCardSearch, limit: number, startKey?: Record<string, any>): DdbQueryRequest => ({
  indexName: s.index,
  partitionKey: s.pk!,
  sortKey: s.sk,
  ascending: true,
  limit,
  startKey,
  conditions: s.conditions,
});

/** Items of the search: the first `limit`, or (count) all of them up to MAX_COUNT_CALLS calls. */
async function run(ctx: CardContext, s: DynamoCardSearch, limit: number): Promise<{ items: Record<string, any>[]; count: number; more: boolean; read: number }> {
  const table = tableOf(ctx);
  let count = 0;
  let read = 0;
  let calls = 0;
  const items: Record<string, any>[] = [];
  const keep = (page: Record<string, any>[]) => {
    count += page.length;
    if (items.length < limit) items.push(...page.slice(0, limit - items.length));
  };
  if (s.mode === 'query') {
    let startKey: Record<string, any> | undefined;
    do {
      const page = await queryTable(ctx.profile, ctx.region, table, queryRequest(s, Math.max(limit, 1), startKey));
      keep(page.items);
      read += page.scannedCount ?? page.items.length;
      startKey = page.lastEvaluatedKey;
      calls++;
    } while (startKey && count < limit && calls < MAX_COUNT_CALLS);
    return { items, count, more: !!startKey, read };
  }
  if (s.mode === 'scan') {
    let cursor: string | undefined;
    do {
      const page = await searchTable(ctx.profile, ctx.region, table, s.conditions, Math.max(limit, 1), cursor);
      keep(page.items);
      read += page.scannedCount;
      cursor = page.cursor;
      calls++;
    } while (cursor && count < limit && calls < MAX_COUNT_CALLS);
    return { items, count, more: !!cursor, read };
  }
  let token: string | undefined;
  do {
    const page = await executePartiQL(ctx.profile, ctx.region, s.statement!, token, Math.max(limit, 1));
    keep(page.items);
    token = page.nextToken;
    calls++;
  } while (token && count < limit && calls < MAX_COUNT_CALLS);
  return { items, count, more: !!token, read: count };
}

const cell = (value: unknown) => {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text === undefined ? '' : text.length > 80 ? `${text.slice(0, 79)}…` : text;
};

/** Items as a table: key attributes first, then the most common others (at most 6 columns). */
function itemsPreview(items: Record<string, any>[], keys: string[], title: Text, more: boolean, emptyMessage: Text, note?: Text): Preview {
  const seen = new Map<string, number>();
  for (const item of items) for (const k of Object.keys(item)) seen.set(k, (seen.get(k) ?? 0) + 1);
  const others = [...seen].filter(([k]) => !keys.includes(k)).sort((a, b) => b[1] - a[1]).map(([k]) => k);
  const columns = [...keys.filter((k) => seen.has(k)), ...others].slice(0, 6);
  return { title, columns: columns.map((c) => t(c, c)), rows: items.slice(0, PREVIEW_ROWS).map((item) => columns.map((c) => cell(item[c]))), more, emptyMessage, note };
}

const MODE_NAMES: Record<DynamoCardSearch['mode'], Text> = {
  query: t('Query', 'Query'),
  scan: t('Filter (table scan)', 'Filtre (tablo taraması)'),
  partiql: t('PartiQL', 'PartiQL'),
};

export const dynamodbCards: ServiceCards = {
  service: 'dynamodb',
  options: {
    async 'dynamodb.tables'({ profile, region }) {
      return (await listTables(profile, region)).map((name) => ({ value: name, label: name }));
    },
    /** The table and its indexes with their key schema - the Query form's "query on" list. */
    async 'dynamodb.keySchema'({ profile, region, deps }) {
      if (!new RegExp(TABLE_PATTERN).test(deps.table || '')) return [];
      const table = (await createDdbClient(profile, region).send(new DescribeTableCommand({ TableName: deps.table }))).Table;
      if (!table) return [];
      const type = (name?: string) => table.AttributeDefinitions?.find((a) => a.AttributeName === name)?.AttributeType ?? 'S';
      const keys = (schema?: { AttributeName?: string; KeyType?: string }[]) => {
        const pk = schema?.find((k) => k.KeyType === 'HASH')?.AttributeName;
        const sk = schema?.find((k) => k.KeyType === 'RANGE')?.AttributeName;
        return { pk: pk && { name: pk, type: type(pk) }, sk: sk && { name: sk, type: type(sk) } };
      };
      const describe = (k: ReturnType<typeof keys>) => [k.pk && `${k.pk.name} (${k.pk.type})`, k.sk && `${k.sk.name} (${k.sk.type})`].filter(Boolean).join(' · ');
      const base = keys(table.KeySchema);
      return [
        { value: '', label: deps.table, detail: describe(base), meta: base },
        ...(table.GlobalSecondaryIndexes || []).map((i) => ({ value: i.IndexName || '', label: `GSI ${i.IndexName}`, detail: describe(keys(i.KeySchema)), meta: keys(i.KeySchema) })),
        ...(table.LocalSecondaryIndexes || []).map((i) => ({ value: i.IndexName || '', label: `LSI ${i.IndexName}`, detail: describe(keys(i.KeySchema)), meta: keys(i.KeySchema) })),
      ];
    },
    /** Attribute names for the Filter Builder, A → Z - sparse ones too (see getTableAttributeNames). */
    async 'dynamodb.attributes'({ profile, region, deps }) {
      if (!new RegExp(TABLE_PATTERN).test(deps.table || '')) return [];
      const { names } = await getTableAttributeNames(profile, region, deps.table);
      return names.map((n) => ({ value: n, label: n }));
    },
  },
  templates: [
    {
      id: 'dynamodb.search',
      kind: 'metric',
      name: t('Search', 'Arama'),
      description: t(
        'A search like on the DynamoDB screen - Query, Filter Builder over the table, or PartiQL. The card shows how many items it returns; Run opens the table with the same search.',
        'DynamoDB ekranındaki gibi bir arama - Query, tabloda Filter Builder ya da PartiQL. Kart kaç kayıt döndüğünü gösterir; Run tabloyu aynı aramayla açar.',
      ),
      icon: 'line.3.horizontal.decrease.circle.fill',
      params: [
        { key: 'table', label: t('Table', 'Tablo'), type: 'combo', source: 'dynamodb.tables', required: true, pattern: TABLE_PATTERN },
        {
          key: 'search',
          label: t('Search', 'Arama'),
          type: 'dynamoSearch',
          source: 'dynamodb.keySchema',
          dependsOn: ['table'],
          required: true,
          maxLength: 8000,
          hint: t(
            'The count reads every matching item (Query: the partition, Filter: the whole table) and uses read capacity; it stops after 20 calls and then shows "at least".',
            'Sayım eşleşen her kaydı okur (Query: partition, Filtre: bütün tablo) ve okuma kapasitesi harcar; 20 çağrıdan sonra durur ve "en az" gösterir.',
          ),
        },
      ],
      async value(ctx) {
        const s = parseSearch(ctx.params.search);
        const result = await run(ctx, s, Number.MAX_SAFE_INTEGER);
        return { value: result.count, unit: t('items', 'kayıt'), details: [MODE_NAMES[s.mode]], truncated: result.more };
      },
      async preview(ctx) {
        const s = parseSearch(ctx.params.search);
        const result = await run(ctx, s, PREVIEW_ROWS);
        const keys = s.pk ? [s.pk.name, ...(s.sk ? [s.sk.name] : [])] : [];
        return itemsPreview(
          result.items,
          keys,
          t(`Matching items - ${MODE_NAMES[s.mode].en} (${result.count}${result.more ? '+' : ''})`, `Eşleşen kayıtlar - ${MODE_NAMES[s.mode].tr} (${result.count}${result.more ? '+' : ''})`),
          result.more,
          t('No items match this search.', 'Bu aramaya uyan kayıt yok.'),
          s.mode === 'partiql' ? undefined : t(`${result.read} items were read.`, `${result.read} kayıt okundu.`),
        );
      },
      // Run: the table on the DynamoDB screen, with the same search run there.
      link: (ctx) => ({ service: 'dynamodb', resource: ctx.params.table, query: ctx.params.search }),
    },
    {
      id: 'dynamodb.itemCount',
      kind: 'metric',
      name: t('Table item count', 'Tablo kayıt sayısı'),
      description: t("The table's item count and size as AWS reports them - free, refreshed by AWS about every 6 hours.", 'Tablonun AWS\'nin bildirdiği kayıt sayısı ve boyutu - ücretsiz, AWS yaklaşık 6 saatte bir günceller.'),
      icon: 'tablecells.fill',
      params: [{ key: 'table', label: t('Table', 'Tablo'), type: 'combo', source: 'dynamodb.tables', required: true, pattern: TABLE_PATTERN }],
      async value(ctx) {
        const table = (await createDdbClient(ctx.profile, ctx.region).send(new DescribeTableCommand({ TableName: tableOf(ctx) }))).Table;
        const mb = ((table?.TableSizeBytes ?? 0) / 1_048_576).toFixed(1);
        return { value: table?.ItemCount ?? 0, unit: t('items', 'kayıt'), details: [t(`${mb} MB`, `${mb} MB`)], approximate: true };
      },
      async preview(ctx) {
        const name = tableOf(ctx);
        const c = createDdbClient(ctx.profile, ctx.region);
        const table = (await c.send(new DescribeTableCommand({ TableName: name }))).Table;
        const res = await c.send(new ScanCommand({ TableName: name, Limit: 10 }));
        const keys = (table?.KeySchema || []).map((k) => k.AttributeName || '');
        return itemsPreview((res.Items || []).map(unmarshallPlain), keys, t(`First items of ${name}`, `${name} tablosunun ilk kayıtları`), !!res.LastEvaluatedKey, t('The table is empty.', 'Tablo boş.'), t('A 10-item scan, for a look at the data.', 'Veriye bakmak için 10 kayıtlık bir tarama.'));
      },
      link: (ctx) => ({ service: 'dynamodb', resource: ctx.params.table }),
    },
  ],
};
