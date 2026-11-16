import {
  DataSyncClient,
  ListTasksCommand,
  DescribeTaskCommand,
  ListTaskExecutionsCommand,
  DescribeTaskExecutionCommand,
  ListLocationsCommand,
  ListAgentsCommand,
  DescribeAgentCommand,
  ListTagsForResourceCommand as DsListTags,
  TagResourceCommand as DsTag,
  UntagResourceCommand as DsUntag,
} from '@aws-sdk/client-datasync';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const bytes = (b?: number) => (b === undefined ? undefined : b >= 1e12 ? `${(b / 1e12).toFixed(2)} TB` : b >= 1e9 ? `${(b / 1e9).toFixed(2)} GB` : `${(b / 1e6).toFixed(1)} MB`);

/** DataSync. */
const ds = (p: string, r: string) => new DataSyncClient(clientConfig(p, r));
/** Location type from its URI scheme (s3://, efs://, smb://, nfs://…); location details (credentials) are never read. */
const locationType = (uri?: string) => uri?.split('://')[0]?.toUpperCase();

export const dataSyncAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = ds(profile, region);
    const [tasks, locations, agents] = await Promise.all([
      pageAll((NextToken) => c.send(new ListTasksCommand({ NextToken })), (r) => r.Tasks, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListLocationsCommand({ NextToken })), (r) => r.Locations, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListAgentsCommand({ NextToken })), (r) => r.Agents, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      ...tasks.map((t) => ({ id: `task:${t.TaskArn}`, name: t.Name || lastPart(t.TaskArn) || '', group: 'Tasks', status: t.Status })).sort(byName),
      ...locations.map((l) => ({ id: `loc:${l.LocationArn}`, name: l.LocationUri || lastPart(l.LocationArn) || '', group: 'Locations', info: locationType(l.LocationUri) })).sort(byName),
      ...agents.map((a) => ({ id: `agent:${a.AgentArn}`, name: a.Name || lastPart(a.AgentArn) || '', group: 'Agents', status: a.Status, info: a.Platform?.Version })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = ds(profile, region);
    const [kind, arn] = splitId(id);
    const errors: string[] = [];
    const tags = async () => (await settle({ t: pageAll((NextToken) => c.send(new DsListTags({ ResourceArn: arn, NextToken })), (r) => r.Tags, (r) => r.NextToken) }, errors)).t;
    if (kind === 'task') {
      const t = await c.send(new DescribeTaskCommand({ TaskArn: arn }));
      const [runs, tg] = await Promise.all([pageAll((NextToken) => c.send(new ListTaskExecutionsCommand({ TaskArn: arn, NextToken })), (r) => r.TaskExecutions, (r) => r.NextToken).catch(() => []), tags()]);
      const latest = runs.at(-1)?.TaskExecutionArn ? await c.send(new DescribeTaskExecutionCommand({ TaskExecutionArn: runs.at(-1)!.TaskExecutionArn })).catch(() => undefined) : undefined;
      const o = t.Options;
      return {
        id,
        title: t.Name || lastPart(arn) || arn,
        subtitle: 'DataSync task',
        status: t.Status,
        arn,
        tabs: [
          tab('Details', {
            sections: [
              section('Task', [
                ['Status', t.Status],
                ['Error', t.ErrorDetail],
                ['Source', lastPart(t.SourceLocationArn)],
                ['Destination', lastPart(t.DestinationLocationArn)],
                ['Schedule', t.Schedule?.ScheduleExpression],
                ['Includes', (t.Includes || []).map((f) => f.Value)],
                ['Excludes', (t.Excludes || []).map((f) => f.Value)],
                ['Log group', t.CloudWatchLogGroupArn],
                ['Created', t.CreationTime],
              ]),
              section('Options', [['Verify', o?.VerifyMode], ['Overwrite', o?.OverwriteMode], ['Transfer mode', o?.TransferMode], ['Preserve deleted files', o?.PreserveDeletedFiles], ['Bandwidth limit', o?.BytesPerSecond && o.BytesPerSecond > 0 ? `${bytes(o.BytesPerSecond)}/s` : 'Unlimited'], ['Log level', o?.LogLevel]]),
              ...(latest
                ? [section('Latest run', [['Status', latest.Status], ['Started', latest.StartTime], ['Files transferred', latest.FilesTransferred], ['Bytes transferred', bytes(latest.BytesTransferred)], ['Error', latest.Result?.ErrorDetail]])]
                : []),
            ],
            tables: [table(['Execution', 'Status'], runs.slice(-25).reverse().map((r) => [lastPart(r.TaskExecutionArn), r.Status]), { title: 'Recent executions', statusColumn: 1, emptyMessage: 'Never run' })],
          }),
        ],
        tags: tagList(tg),
        actions: [],
        errors,
      };
    }
    if (kind === 'loc') {
      const uri = (await pageAll((NextToken) => c.send(new ListLocationsCommand({ NextToken })), (r) => r.Locations, (r) => r.NextToken)).find((l) => l.LocationArn === arn)?.LocationUri;
      return { id, title: uri || arn, subtitle: `${locationType(uri) ?? ''} location`, arn, tabs: [tab('Details', { sections: [section('Location', [['URI', uri], ['Type', locationType(uri)], ['ARN', arn]], { note: 'Location settings (and any credentials) are not read by this app.' })] })], tags: tagList(await tags()), actions: [], errors };
    }
    if (kind === 'agent') {
      const a = await c.send(new DescribeAgentCommand({ AgentArn: arn }));
      return {
        id,
        title: a.Name || lastPart(arn) || arn,
        subtitle: 'DataSync agent',
        status: a.Status,
        arn,
        tabs: [tab('Details', { sections: [section('Agent', [['Status', a.Status], ['Endpoint type', a.EndpointType], ['Version', a.Platform?.Version], ['Last connection', a.LastConnectionTime], ['Created', a.CreationTime], ['VPC endpoint', a.PrivateLinkConfig?.VpcEndpointId]])] })],
        tags: tagList(await tags()),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown DataSync page: ${id}`, 400);
  },
  async addTag(profile, region, id, _arn, key, value) {
    await ds(profile, region).send(new DsTag({ ResourceArn: splitId(id)[1], Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await ds(profile, region).send(new DsUntag({ ResourceArn: splitId(id)[1], Keys: [key] }));
  },
  countable: (row) => row.id.startsWith('task:'),
};
