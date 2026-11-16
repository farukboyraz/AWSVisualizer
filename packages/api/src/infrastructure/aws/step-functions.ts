import {
  SFNClient,
  ListStateMachinesCommand,
  DescribeStateMachineCommand,
  ListExecutionsCommand,
  ListActivitiesCommand,
  DescribeActivityCommand,
  ListTagsForResourceCommand as SfnListTags,
  TagResourceCommand as SfnTag,
  UntagResourceCommand as SfnUntag,
} from '@aws-sdk/client-sfn';
import type { PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const pretty = (s?: string) => {
  if (!s) return undefined;
  try {
    return JSON.stringify(JSON.parse(s), null, 2);
  } catch {
    return s;
  }
};

/** Step Functions. */
const sfn = (p: string, r: string) => new SFNClient(clientConfig(p, r));

export const stepFunctionsAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = sfn(profile, region);
    const [machines, activities] = await Promise.all([
      pageAll((nextToken) => c.send(new ListStateMachinesCommand({ nextToken })), (r) => r.stateMachines, (r) => r.nextToken),
      pageAll((nextToken) => c.send(new ListActivitiesCommand({ nextToken })), (r) => r.activities, (r) => r.nextToken).catch(() => []),
    ]);
    return [
      ...machines.map((m) => ({ id: `sm:${m.stateMachineArn}`, name: m.name || '', group: 'State machines', info: m.type })).sort(byName),
      ...activities.map((a) => ({ id: `act:${a.activityArn}`, name: a.name || '', group: 'Activities' })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = sfn(profile, region);
    const [kind, arn] = splitId(id);
    const errors: string[] = [];
    if (kind === 'sm') {
      const m = await c.send(new DescribeStateMachineCommand({ stateMachineArn: arn }));
      const parts = await settle({ runs: c.send(new ListExecutionsCommand({ stateMachineArn: arn, maxResults: 25 })), tags: c.send(new SfnListTags({ resourceArn: arn })) }, errors);
      const runs = parts.runs?.executions || [];
      const tabs: PageTab[] = [
        tab('Details', {
          sections: [
            section('State machine', [
              ['Type', m.type],
              ['Status', m.status],
              ['Description', m.description],
              ['Role', m.roleArn],
              ['Logging', m.loggingConfiguration?.level],
              ['Log destination', (m.loggingConfiguration?.destinations || []).map((d) => d.cloudWatchLogsLogGroup?.logGroupArn)],
              ['X-Ray tracing', m.tracingConfiguration?.enabled],
              ['Encryption', m.encryptionConfiguration?.type],
              ['Created', m.creationDate],
            ]),
          ],
        }),
        tab('Executions', {
          tables: [
            table(['Execution', 'Status', 'Started', 'Stopped', 'Redrives'], runs.map((r) => [r.name, r.status, r.startDate, r.stopDate, r.redriveCount]), {
              statusColumn: 1,
              title: m.type === 'EXPRESS' ? 'Express executions are only in CloudWatch Logs' : 'Last 25 executions',
              emptyMessage: 'No executions',
            }),
          ],
        }),
      ];
      if (pretty(m.definition)) tabs.push(tab('Definition (ASL)', { json: pretty(m.definition) }));
      return { id, title: m.name || arn, subtitle: `${m.type} state machine`, status: runs[0]?.status ?? m.status, arn, tabs, tags: tagList(parts.tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))), actions: [], errors };
    }
    if (kind === 'act') {
      const a = await c.send(new DescribeActivityCommand({ activityArn: arn }));
      const { tags } = await settle({ tags: c.send(new SfnListTags({ resourceArn: arn })) }, errors);
      return { id, title: a.name || arn, subtitle: 'Activity', arn, tabs: [tab('Details', { sections: [section('Activity', [['Name', a.name], ['Encryption', a.encryptionConfiguration?.type], ['Created', a.creationDate]])] })], tags: tagList(tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))), actions: [], errors };
    }
    throw httpError(`Unknown Step Functions page: ${id}`, 400);
  },
  async addTag(profile, region, id, _arn, key, value) {
    await sfn(profile, region).send(new SfnTag({ resourceArn: splitId(id)[1], tags: [{ key, value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await sfn(profile, region).send(new SfnUntag({ resourceArn: splitId(id)[1], tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('sm:'),
};
