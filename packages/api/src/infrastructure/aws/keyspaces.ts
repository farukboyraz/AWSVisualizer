import {
  KeyspacesClient,
  ListKeyspacesCommand,
  ListTablesCommand,
  GetKeyspaceCommand,
  GetTableCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  CreateKeyspaceCommand,
  type TableSummary,
} from '@aws-sdk/client-keyspaces';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new KeyspacesClient({ region: r, credentials: cachedCredentials(p) });
/** AWS-managed keyspaces every account has; the console lists them separately. */
const isSystem = (name: string) => name.startsWith('system');

async function tablesOf(c: KeyspacesClient, keyspaceName: string): Promise<TableSummary[]> {
  const out: TableSummary[] = [];
  let nextToken: string | undefined;
  do {
    const res = await c.send(new ListTablesCommand({ keyspaceName, nextToken }));
    out.push(...(res.tables || []));
    nextToken = res.nextToken;
  } while (nextToken);
  return out;
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const keyspaces: { keyspaceName?: string; replicationStrategy?: string }[] = [];
  let nextToken: string | undefined;
  do {
    const res = await c.send(new ListKeyspacesCommand({ nextToken }));
    keyspaces.push(...(res.keyspaces || []));
    nextToken = res.nextToken;
  } while (nextToken);
  const user = keyspaces.filter((k) => k.keyspaceName && !isSystem(k.keyspaceName));
  const tables = await Promise.all(user.map((k) => tablesOf(c, k.keyspaceName!).catch(() => [] as TableSummary[])));
  const out: PageSummary[] = [];
  user.forEach((k, i) => {
    out.push({ id: `ks:${k.keyspaceName}`, name: k.keyspaceName!, group: k.keyspaceName, info: `Keyspace · ${tables[i].length} tables · ${k.replicationStrategy === 'MULTI_REGION' ? 'multi-Region' : 'single-Region'}` });
    for (const t of tables[i].sort((a, b) => (a.tableName || '').localeCompare(b.tableName || ''))) {
      out.push({ id: `tb:${t.keyspaceName}/${t.tableName}`, name: t.tableName || '', group: k.keyspaceName, info: 'Table' });
    }
  });
  return out.sort((a, b) => (a.group || '').localeCompare(b.group || ''));
}

async function tagsOf(c: KeyspacesClient, arn: string) {
  const res = await c.send(new ListTagsForResourceCommand({ resourceArn: arn }));
  return (res.tags || []).map((t) => ({ key: t.key || '', value: t.value || '' }));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];

  if (kind === 'ks') {
    const ks = await c.send(new GetKeyspaceCommand({ keyspaceName: rest }));
    const { tables, tags } = await settle({ tables: tablesOf(c, rest), tags: tagsOf(c, ks.resourceArn || '') }, errors);
    return {
      id,
      title: rest,
      subtitle: 'Keyspace',
      arn: ks.resourceArn,
      tabs: [
        tab('Keyspace', {
          sections: [section('Replication', [['Strategy', ks.replicationStrategy === 'MULTI_REGION' ? 'Multi-Region' : 'Single-Region'], ['Regions', ks.replicationRegions]])],
          tables: [table(['Table'], (tables || []).map((t) => [t.tableName]), { title: 'Tables', emptyMessage: 'No tables in this keyspace' })],
        }),
      ],
      tags,
      actions: [],
      errors,
    };
  }

  if (kind === 'tb') {
    const [keyspaceName, tableName] = rest.split('/');
    const t = await c.send(new GetTableCommand({ keyspaceName, tableName }));
    const { tags } = await settle({ tags: tagsOf(c, t.resourceArn || '') }, errors);
    const s = t.schemaDefinition;
    const pk = new Set((s?.partitionKeys || []).map((k) => k.name));
    const ck = new Map((s?.clusteringKeys || []).map((k) => [k.name, k.orderBy]));
    const st = new Set((s?.staticColumns || []).map((k) => k.name));
    const cap = t.capacitySpecification;
    return {
      id,
      title: tableName,
      subtitle: `${keyspaceName} keyspace`,
      status: t.status,
      arn: t.resourceArn,
      tabs: [
        tab('Overview', {
          sections: [
            section('Settings', [
              ['Status', t.status],
              ['Capacity mode', cap?.throughputMode === 'PAY_PER_REQUEST' ? 'On-demand' : 'Provisioned'],
              ['Read capacity units', cap?.readCapacityUnits],
              ['Write capacity units', cap?.writeCapacityUnits],
              ['Encryption', t.encryptionSpecification?.type === 'CUSTOMER_MANAGED_KMS_KEY' ? `Customer managed key (${t.encryptionSpecification.kmsKeyIdentifier})` : 'AWS owned key'],
              ['Point-in-time recovery', t.pointInTimeRecovery?.status],
              ['Earliest restorable', t.pointInTimeRecovery?.earliestRestorableTimestamp],
              ['Time to live', t.ttl?.status],
              ['Default TTL', t.defaultTimeToLive ? `${t.defaultTimeToLive} s` : undefined],
              ['Client-side timestamps', t.clientSideTimestamps?.status],
              ['Comment', t.comment?.message],
              ['Created', t.creationTimestamp],
            ]),
          ],
        }),
        tab('Schema', {
          tables: [
            table(
              ['Column', 'Type', 'Key'],
              (s?.allColumns || []).map((col) => [
                col.name,
                col.type,
                pk.has(col.name) ? 'Partition key' : ck.has(col.name) ? `Clustering (${ck.get(col.name)})` : st.has(col.name) ? 'Static' : '',
              ]),
            ),
          ],
        }),
        ...(t.replicaSpecifications?.length
          ? [tab('Replicas', { tables: [table(['Region', 'Status', 'Capacity mode'], t.replicaSpecifications.map((r) => [r.region, r.status, r.capacitySpecification?.throughputMode]), { statusColumn: 1 })] })]
          : []),
      ],
      tags,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown Keyspaces id: ${id}`, 400);
}

export const keyspacesAdapter: PageServiceAdapter = {
  list,
  detail,
  createForms: [
    {
      id: 'keyspace',
      title: 'New keyspace',
      systemImage: 'plus',
      confirmTitle: 'Create keyspace?',
      confirmMessage: 'A single-Region keyspace is created. Keyspaces are free; tables in it are billed.',
      destructive: false,
      form: [
        {
          key: 'name',
          label: { en: 'Keyspace name', tr: 'Keyspace adı' },
          type: 'text',
          required: true,
          maxLength: 48,
          pattern: '^[a-zA-Z0-9][a-zA-Z0-9_]{0,47}$',
          patternMessage: { en: 'letters, digits and _ ; starts with a letter or digit', tr: 'harf, rakam ve _ ; harf ya da rakamla başlar' },
          hint: { en: 'Names starting with "system" are reserved by AWS.', tr: '"system" ile başlayan adlar AWS\'ye ayrılmış.' },
        },
      ],
    },
  ],
  async create(profile, region, form, params) {
    if (form !== 'keyspace') throw httpError(`Unknown form: ${form}`, 400);
    if (isSystem(params.name)) throw httpError('Keyspace names starting with "system" are reserved', 400);
    await client(profile, region).send(new CreateKeyspaceCommand({ keyspaceName: params.name }));
    return `ks:${params.name}`;
  },
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ key, value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    // UntagResource wants the full key/value pair.
    const c = client(profile, region);
    const tag = (await tagsOf(c, arn)).find((t) => t.key === key);
    if (!tag) return;
    await c.send(new UntagResourceCommand({ resourceArn: arn, tags: [{ key: tag.key, value: tag.value }] }));
  },
};
