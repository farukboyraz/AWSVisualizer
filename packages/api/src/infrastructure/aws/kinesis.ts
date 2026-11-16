import {
  KinesisClient,
  ListStreamsCommand,
  DescribeStreamSummaryCommand,
  ListShardsCommand,
  ListStreamConsumersCommand,
  ListTagsForStreamCommand,
  AddTagsToStreamCommand,
  RemoveTagsFromStreamCommand,
} from '@aws-sdk/client-kinesis';
import {
  FirehoseClient,
  ListDeliveryStreamsCommand,
  DescribeDeliveryStreamCommand,
  ListTagsForDeliveryStreamCommand,
  TagDeliveryStreamCommand,
  UntagDeliveryStreamCommand,
  type DestinationDescription,
} from '@aws-sdk/client-firehose';
import {
  KinesisAnalyticsV2Client,
  ListApplicationsCommand,
  DescribeApplicationCommand,
  ListApplicationSnapshotsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-kinesis-analytics-v2';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Kinesis = Data Streams + Data Firehose + Managed Service for Apache Flink (kinesisanalyticsv2). */
const streams = (p: string, r: string) => new KinesisClient({ region: r, credentials: cachedCredentials(p) });
const firehose = (p: string, r: string) => new FirehoseClient({ region: r, credentials: cachedCredentials(p) });
const flink = (p: string, r: string) => new KinesisAnalyticsV2Client({ region: r, credentials: cachedCredentials(p) });

const SHARD_LIMIT = 500;
/** Flink runtime property keys whose values are never shown. */
const SECRET_KEY = /pass(word)?|secret|token|credential|private.?key|api.?key|\bkey\b/i;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const [ds, fh, apps] = await Promise.all([
    pageAll((NextToken) => streams(profile, region).send(new ListStreamsCommand({ NextToken })), (r) => r.StreamSummaries, (r) => r.NextToken),
    pageAll((ExclusiveStartDeliveryStreamName) => firehose(profile, region).send(new ListDeliveryStreamsCommand({ ExclusiveStartDeliveryStreamName })).then((r) => ({ ...r, next: r.HasMoreDeliveryStreams ? r.DeliveryStreamNames?.at(-1) : undefined })), (r) => r.DeliveryStreamNames, (r) => r.next).catch(() => [] as string[]),
    pageAll((NextToken) => flink(profile, region).send(new ListApplicationsCommand({ NextToken })), (r) => r.ApplicationSummaries, (r) => r.NextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...ds.map((s) => ({ id: `ds:${s.StreamName}`, name: s.StreamName || '', group: 'Data streams', status: s.StreamStatus, info: s.StreamModeDetails?.StreamMode })).sort(byName),
    ...fh.map((n) => ({ id: `fh:${n}`, name: n, group: 'Firehose streams' })).sort(byName),
    ...apps.map((a) => ({ id: `flink:${a.ApplicationName}`, name: a.ApplicationName || '', group: 'Managed Apache Flink', status: a.ApplicationStatus, info: [a.RuntimeEnvironment, a.ApplicationMode].filter(Boolean).join(' · ') })).sort(byName),
  ];
}

async function streamPage(profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const c = streams(profile, region);
  const s = (await c.send(new DescribeStreamSummaryCommand({ StreamName: name }))).StreamDescriptionSummary;
  if (!s) throw httpError(`Stream not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      shards: pageAll((NextToken) => c.send(new ListShardsCommand(NextToken ? { NextToken } : { StreamARN: s.StreamARN })), (r) => r.Shards, (r) => r.NextToken, SHARD_LIMIT),
      consumers: pageAll((NextToken) => c.send(new ListStreamConsumersCommand({ StreamARN: s.StreamARN, NextToken })), (r) => r.Consumers, (r) => r.NextToken),
      tags: c.send(new ListTagsForStreamCommand({ StreamARN: s.StreamARN })),
    },
    errors,
  );
  const open = (parts.shards || []).filter((x) => !x.SequenceNumberRange?.EndingSequenceNumber);
  return {
    id,
    title: name,
    subtitle: `${s.StreamModeDetails?.StreamMode ?? ''} data stream`,
    status: s.StreamStatus,
    arn: s.StreamARN,
    tabs: [
      tab('Details', {
        sections: [
          section('Stream', [
            ['Capacity mode', s.StreamModeDetails?.StreamMode],
            ['Open shards', s.OpenShardCount],
            ['Retention (hours)', s.RetentionPeriodHours],
            ['Encryption', s.EncryptionType === 'KMS' ? `KMS ${s.KeyId ?? ''}` : s.EncryptionType],
            ['Enhanced monitoring', (s.EnhancedMonitoring || []).flatMap((m) => m.ShardLevelMetrics || [])],
            ['Enhanced fan-out consumers', s.ConsumerCount],
            ['Created', s.StreamCreationTimestamp],
          ]),
        ],
      }),
      tab('Shards', {
        tables: [
          table(['Shard', 'State', 'Parent', 'Starting hash key', 'Ending hash key'], (parts.shards || []).map((x) => [x.ShardId, x.SequenceNumberRange?.EndingSequenceNumber ? 'CLOSED' : 'OPEN', x.ParentShardId, x.HashKeyRange?.StartingHashKey, x.HashKeyRange?.EndingHashKey]), {
            statusColumn: 1,
            title: `${open.length} open of ${parts.shards?.length ?? 0} shards${(parts.shards?.length ?? 0) >= SHARD_LIMIT ? ` (first ${SHARD_LIMIT})` : ''}`,
            emptyMessage: 'No shards',
          }),
        ],
      }),
      tab('Consumers', {
        tables: [table(['Consumer', 'Status', 'Created'], (parts.consumers || []).map((x) => [x.ConsumerName, x.ConsumerStatus, x.ConsumerCreationTimestamp]), { statusColumn: 1, title: 'Enhanced fan-out consumers', emptyMessage: 'No registered consumers' })],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

/** One readable line per destination - only addresses and settings, never tokens, keys or passwords. */
function destination(d: DestinationDescription): [string, string][] {
  const s3 = d.ExtendedS3DestinationDescription ?? d.S3DestinationDescription;
  const buffer = (h?: { SizeInMBs?: number; IntervalInSeconds?: number }) => (h ? `${h.SizeInMBs ?? '-'} MB / ${h.IntervalInSeconds ?? '-'} s` : '-');
  if (d.ExtendedS3DestinationDescription || (d.S3DestinationDescription && !d.RedshiftDestinationDescription)) {
    const x = d.ExtendedS3DestinationDescription;
    return [
      ['Destination', 'Amazon S3'],
      ['Bucket', s3?.BucketARN?.split(':').pop() ?? '-'],
      ['Prefix', s3?.Prefix ?? '-'],
      ['Error prefix', s3?.ErrorOutputPrefix ?? '-'],
      ['Buffer', buffer(s3?.BufferingHints)],
      ['Compression', s3?.CompressionFormat ?? '-'],
      ['Format conversion', x?.DataFormatConversionConfiguration?.Enabled ? 'Enabled' : 'Disabled'],
      ['Dynamic partitioning', x?.DynamicPartitioningConfiguration?.Enabled ? 'Enabled' : 'Disabled'],
      ['Transform (Lambda)', x?.ProcessingConfiguration?.Enabled ? 'Enabled' : 'Disabled'],
    ];
  }
  if (d.RedshiftDestinationDescription) return [['Destination', 'Amazon Redshift'], ['Cluster JDBC URL', d.RedshiftDestinationDescription.ClusterJDBCURL ?? '-'], ['Table', d.RedshiftDestinationDescription.CopyCommand?.DataTableName ?? '-'], ['User', d.RedshiftDestinationDescription.Username ?? '-']];
  if (d.AmazonopensearchserviceDestinationDescription) return [['Destination', 'OpenSearch Service'], ['Domain', d.AmazonopensearchserviceDestinationDescription.DomainARN ?? d.AmazonopensearchserviceDestinationDescription.ClusterEndpoint ?? '-'], ['Index', d.AmazonopensearchserviceDestinationDescription.IndexName ?? '-'], ['Buffer', buffer(d.AmazonopensearchserviceDestinationDescription.BufferingHints)]];
  if (d.ElasticsearchDestinationDescription) return [['Destination', 'Elasticsearch'], ['Domain', d.ElasticsearchDestinationDescription.DomainARN ?? '-'], ['Index', d.ElasticsearchDestinationDescription.IndexName ?? '-']];
  if (d.SplunkDestinationDescription) return [['Destination', 'Splunk'], ['HEC endpoint', d.SplunkDestinationDescription.HECEndpoint ?? '-'], ['Endpoint type', d.SplunkDestinationDescription.HECEndpointType ?? '-'], ['HEC token', 'not shown']];
  if (d.HttpEndpointDestinationDescription) return [['Destination', 'HTTP endpoint'], ['Name', d.HttpEndpointDestinationDescription.EndpointConfiguration?.Name ?? '-'], ['URL', d.HttpEndpointDestinationDescription.EndpointConfiguration?.Url ?? '-'], ['Buffer', buffer(d.HttpEndpointDestinationDescription.BufferingHints)]];
  if (d.SnowflakeDestinationDescription) return [['Destination', 'Snowflake'], ['Account URL', d.SnowflakeDestinationDescription.AccountUrl ?? '-'], ['Database', d.SnowflakeDestinationDescription.Database ?? '-'], ['Table', d.SnowflakeDestinationDescription.Table ?? '-']];
  return [['Destination', 'Other']];
}

async function firehosePage(profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const c = firehose(profile, region);
  const d = (await c.send(new DescribeDeliveryStreamCommand({ DeliveryStreamName: name }))).DeliveryStreamDescription;
  if (!d) throw httpError(`Firehose stream not found: ${name}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: pageAll((ExclusiveStartTagKey) => c.send(new ListTagsForDeliveryStreamCommand({ DeliveryStreamName: name, ExclusiveStartTagKey })).then((r) => ({ ...r, next: r.HasMoreTags ? r.Tags?.at(-1)?.Key : undefined })), (r) => r.Tags, (r) => r.next) }, errors);
  const src = d.Source;
  return {
    id,
    title: name,
    subtitle: `Firehose stream · ${d.DeliveryStreamType}`,
    status: d.DeliveryStreamStatus,
    arn: d.DeliveryStreamARN,
    tabs: [
      tab('Details', {
        sections: [
          section('Stream', [
            ['Source', d.DeliveryStreamType],
            ['Source stream', src?.KinesisStreamSourceDescription?.KinesisStreamARN ?? src?.MSKSourceDescription?.MSKClusterARN],
            ['Encryption', d.DeliveryStreamEncryptionConfiguration?.Status],
            ['Failure', d.FailureDescription?.Details],
            ['Version', d.VersionId],
            ['Created', d.CreateTimestamp],
            ['Updated', d.LastUpdateTimestamp],
          ]),
          ...(d.Destinations || []).map((x, i) => section(`Destination ${i + 1}`, destination(x))),
        ],
      }),
    ],
    tags: tagList(tags),
    actions: [],
    errors,
  };
}

async function flinkPage(profile: string, region: string, id: string, name: string): Promise<ResourcePage> {
  const c = flink(profile, region);
  const a = (await c.send(new DescribeApplicationCommand({ ApplicationName: name }))).ApplicationDetail;
  if (!a) throw httpError(`Application not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      snapshots: pageAll((NextToken) => c.send(new ListApplicationSnapshotsCommand({ ApplicationName: name, NextToken })), (r) => r.SnapshotSummaries, (r) => r.NextToken, 100),
      tags: c.send(new ListTagsForResourceCommand({ ResourceARN: a.ApplicationARN })),
    },
    errors,
  );
  const cfg = a.ApplicationConfigurationDescription;
  const fl = cfg?.FlinkApplicationConfigurationDescription;
  const code = cfg?.ApplicationCodeConfigurationDescription?.CodeContentDescription;
  const props = cfg?.EnvironmentPropertyDescriptions?.PropertyGroupDescriptions || [];
  return {
    id,
    title: name,
    subtitle: `${a.RuntimeEnvironment ?? ''} application`,
    status: a.ApplicationStatus,
    arn: a.ApplicationARN,
    tabs: [
      tab('Details', {
        sections: [
          section('Application', [
            ['Runtime', a.RuntimeEnvironment],
            ['Status', a.ApplicationStatus],
            ['Mode', a.ApplicationMode],
            ['Version', a.ApplicationVersionId],
            ['Description', a.ApplicationDescription],
            ['Service role', a.ServiceExecutionRole],
            ['Code', code?.S3ApplicationCodeLocationDescription ? `s3://${code.S3ApplicationCodeLocationDescription.BucketARN?.split(':').pop()}/${code.S3ApplicationCodeLocationDescription.FileKey}` : code?.TextContent ? 'Inline' : undefined],
            ['Parallelism', fl?.ParallelismConfigurationDescription ? `${fl.ParallelismConfigurationDescription.CurrentParallelism} (per KPU ${fl.ParallelismConfigurationDescription.ParallelismPerKPU})` : undefined],
            ['Auto scaling', fl?.ParallelismConfigurationDescription?.AutoScalingEnabled],
            ['Checkpointing', fl?.CheckpointConfigurationDescription?.CheckpointingEnabled],
            ['Snapshots', cfg?.ApplicationSnapshotConfigurationDescription?.SnapshotsEnabled],
            ['Logging', (a.CloudWatchLoggingOptionDescriptions || []).map((l) => l.LogStreamARN)],
            ['Created', a.CreateTimestamp],
            ['Updated', a.LastUpdateTimestamp],
          ]),
        ],
        tables: [
          table(['Group', 'Property', 'Value'], props.flatMap((g) => Object.entries(g.PropertyMap || {}).map(([k, v]) => [g.PropertyGroupId, k, SECRET_KEY.test(k) ? '•••• (hidden)' : v])), { title: 'Runtime properties', emptyMessage: 'No runtime properties' }),
        ],
      }),
      tab('Snapshots', {
        tables: [table(['Snapshot', 'Status', 'App version', 'Created'], (parts.snapshots || []).map((s) => [s.SnapshotName, s.SnapshotStatus, s.ApplicationVersionId, s.SnapshotCreationTimestamp]), { statusColumn: 1, emptyMessage: 'No snapshots' })],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, name] = splitId(id);
  if (kind === 'ds') return streamPage(profile, region, id, name);
  if (kind === 'fh') return firehosePage(profile, region, id, name);
  if (kind === 'flink') return flinkPage(profile, region, id, name);
  throw httpError(`Unknown Kinesis page: ${id}`, 400);
}

export const kinesisAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    const [kind, name] = splitId(id);
    if (kind === 'ds') await streams(profile, region).send(new AddTagsToStreamCommand({ StreamARN: arn || undefined, StreamName: arn ? undefined : name, Tags: { [key]: value } }));
    else if (kind === 'fh') await firehose(profile, region).send(new TagDeliveryStreamCommand({ DeliveryStreamName: name, Tags: [{ Key: key, Value: value }] }));
    else if (kind === 'flink' && arn) await flink(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
    else throw httpError(`Unknown Kinesis resource: ${id}`, 400);
  },
  async removeTag(profile, region, id, arn, key) {
    const [kind, name] = splitId(id);
    if (kind === 'ds') await streams(profile, region).send(new RemoveTagsFromStreamCommand({ StreamARN: arn || undefined, StreamName: arn ? undefined : name, TagKeys: [key] }));
    else if (kind === 'fh') await firehose(profile, region).send(new UntagDeliveryStreamCommand({ DeliveryStreamName: name, TagKeys: [key] }));
    else if (kind === 'flink' && arn) await flink(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
    else throw httpError(`Unknown Kinesis resource: ${id}`, 400);
  },
};
