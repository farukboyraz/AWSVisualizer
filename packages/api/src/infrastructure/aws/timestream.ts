import {
  TimestreamWriteClient,
  ListDatabasesCommand,
  ListTablesCommand,
  DescribeDatabaseCommand,
  DescribeTableCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Database,
  type Table,
} from '@aws-sdk/client-timestream-write';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Timestream resolves a per-account endpoint first (endpointDiscovery is on by default in the SDK). */
const client = (p: string, r: string) => new TimestreamWriteClient({ region: r, credentials: cachedCredentials(p) });

async function databases(c: TimestreamWriteClient): Promise<Database[]> {
  const out: Database[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new ListDatabasesCommand({ NextToken }));
    out.push(...(res.Databases || []));
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

async function tables(c: TimestreamWriteClient, DatabaseName: string): Promise<Table[]> {
  const out: Table[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new ListTablesCommand({ DatabaseName, NextToken }));
    out.push(...(res.Tables || []));
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

const retention = (t?: Table) => t?.RetentionProperties;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const dbs = await databases(c);
  const all = await Promise.all(dbs.map((d) => tables(c, d.DatabaseName || '').catch(() => [] as Table[])));
  const out: PageSummary[] = [];
  dbs.forEach((d, i) => {
    out.push({ id: `db:${d.DatabaseName}`, name: d.DatabaseName || '', group: d.DatabaseName, info: `Database · ${d.TableCount ?? all[i].length} tables` });
    for (const t of all[i]) {
      const r = retention(t);
      out.push({
        id: `tb:${d.DatabaseName}/${t.TableName}`,
        name: t.TableName || '',
        group: d.DatabaseName,
        status: t.TableStatus,
        info: r ? `memory ${r.MemoryStoreRetentionPeriodInHours} h · magnetic ${r.MagneticStoreRetentionPeriodInDays} d` : 'Table',
      });
    }
  });
  return out.sort((a, b) => (a.group || '').localeCompare(b.group || ''));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];

  if (kind === 'db') {
    const d = (await c.send(new DescribeDatabaseCommand({ DatabaseName: rest }))).Database;
    if (!d) throw httpError(`Database not found: ${rest}`, 404);
    const { tbls, tags } = await settle(
      { tbls: tables(c, rest), tags: c.send(new ListTagsForResourceCommand({ ResourceARN: d.Arn })) },
      errors,
    );
    return {
      id,
      title: rest,
      subtitle: 'Timestream database',
      arn: d.Arn,
      tabs: [
        tab('Database', {
          sections: [section('Details', [['Tables', d.TableCount], ['KMS key', d.KmsKeyId], ['Created', d.CreationTime], ['Last updated', d.LastUpdatedTime]])],
          tables: [
            table(
              ['Table', 'Status', 'Memory store', 'Magnetic store'],
              (tbls || []).map((t) => [t.TableName, t.TableStatus, `${retention(t)?.MemoryStoreRetentionPeriodInHours ?? '-'} hours`, `${retention(t)?.MagneticStoreRetentionPeriodInDays ?? '-'} days`]),
              { title: 'Tables', statusColumn: 1, emptyMessage: 'No tables' },
            ),
          ],
        }),
      ],
      tags: tags ? tagList(tags.Tags) : undefined,
      actions: [],
      errors,
    };
  }

  if (kind === 'tb') {
    const [DatabaseName, TableName] = rest.split('/');
    const t = (await c.send(new DescribeTableCommand({ DatabaseName, TableName }))).Table;
    if (!t) throw httpError(`Table not found: ${rest}`, 404);
    const { tags } = await settle({ tags: c.send(new ListTagsForResourceCommand({ ResourceARN: t.Arn })) }, errors);
    const m = t.MagneticStoreWriteProperties;
    const s3 = m?.MagneticStoreRejectedDataLocation?.S3Configuration;
    return {
      id,
      title: TableName,
      subtitle: `${DatabaseName} database`,
      status: t.TableStatus,
      arn: t.Arn,
      tabs: [
        tab('Table', {
          sections: [
            section('Data retention', [
              ['Memory store', `${retention(t)?.MemoryStoreRetentionPeriodInHours ?? '-'} hours`],
              ['Magnetic store', `${retention(t)?.MagneticStoreRetentionPeriodInDays ?? '-'} days`],
              ['Magnetic store writes', m?.EnableMagneticStoreWrites],
              ['Rejected data location', s3?.BucketName && `s3://${s3.BucketName}/${s3.ObjectKeyPrefix ?? ''}`],
            ]),
            section('Details', [['Created', t.CreationTime], ['Last updated', t.LastUpdatedTime]]),
          ],
          tables: [
            table(
              ['Partition key', 'Type', 'Enforcement'],
              (t.Schema?.CompositePartitionKey || []).map((k) => [k.Name ?? '(measure name)', k.Type, k.EnforcementInRecord]),
              { title: 'Schema', emptyMessage: 'Default partitioning (measure name)' },
            ),
          ],
        }),
      ],
      tags: tags ? tagList(tags.Tags) : undefined,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown Timestream id: ${id}`, 400);
}

export const timestreamAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
};
