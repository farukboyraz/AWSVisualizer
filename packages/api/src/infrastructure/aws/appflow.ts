import {
  AppflowClient,
  ListFlowsCommand,
  DescribeFlowCommand,
  DescribeFlowExecutionRecordsCommand,
  DescribeConnectorProfilesCommand,
  TagResourceCommand as AfTag,
  UntagResourceCommand as AfUntag,
} from '@aws-sdk/client-appflow';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** AppFlow. */
const af = (p: string, r: string) => new AppflowClient(clientConfig(p, r));

export const appFlowAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = af(profile, region);
    const [flows, profiles] = await Promise.all([
      pageAll((nextToken) => c.send(new ListFlowsCommand({ nextToken })), (r) => r.flows, (r) => r.nextToken),
      pageAll((nextToken) => c.send(new DescribeConnectorProfilesCommand({ nextToken })), (r) => r.connectorProfileDetails, (r) => r.nextToken).catch(() => []),
    ]);
    return [
      ...flows.map((f) => ({ id: `flow:${f.flowName}`, name: f.flowName || '', group: 'Flows', status: f.flowStatus, info: `${f.sourceConnectorType} → ${f.destinationConnectorType} · ${f.triggerType}` })).sort(byName),
      ...profiles.map((p) => ({ id: `prof:${p.connectorProfileName}`, name: p.connectorProfileName || '', group: 'Connections', info: p.connectorType })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = af(profile, region);
    const [kind, name] = splitId(id);
    const errors: string[] = [];
    if (kind === 'flow') {
      const f = await c.send(new DescribeFlowCommand({ flowName: name }));
      const { runs } = await settle({ runs: c.send(new DescribeFlowExecutionRecordsCommand({ flowName: name, maxResults: 25 })) }, errors);
      const src = f.sourceFlowConfig;
      return {
        id,
        title: name,
        subtitle: 'AppFlow flow',
        status: f.flowStatus,
        arn: f.flowArn,
        tabs: [
          tab('Details', {
            sections: [
              section('Flow', [
                ['Status', f.flowStatus],
                ['Status message', f.flowStatusMessage],
                ['Description', f.description],
                ['Source', `${src?.connectorType} (${src?.connectorProfileName ?? 'no profile'})`],
                ['Destinations', (f.destinationFlowConfigList || []).map((d) => `${d.connectorType} (${d.connectorProfileName ?? '-'})`)],
                ['Trigger', f.triggerConfig?.triggerType],
                ['Schedule', f.triggerConfig?.triggerProperties?.Scheduled?.scheduleExpression],
                ['Last run', f.lastRunExecutionDetails?.mostRecentExecutionStatus],
                ['Last run message', f.lastRunExecutionDetails?.mostRecentExecutionMessage],
                ['KMS key', f.kmsArn],
                ['Created', f.createdAt],
                ['Updated', f.lastUpdatedAt],
              ]),
            ],
            tables: [table(['Task', 'Source fields', 'Destination field'], (f.tasks || []).map((t) => [t.taskType, (t.sourceFields || []).slice(0, 5), t.destinationField]), { title: 'Mapping tasks', emptyMessage: 'No tasks' })],
          }),
          tab('Runs', {
            tables: [
              table(['Execution', 'Status', 'Started', 'Updated', 'Records', 'Bytes', 'Error'], (runs?.flowExecutions || []).map((r) => [r.executionId?.slice(0, 12), r.executionStatus, r.startedAt, r.lastUpdatedAt, r.executionResult?.recordsProcessed, r.executionResult?.bytesProcessed, r.executionResult?.errorInfo?.executionMessage]), {
                statusColumn: 1,
                title: 'Last 25 runs',
                emptyMessage: 'Never run',
              }),
            ],
          }),
        ],
        tags: tagMap(f.tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'prof') {
      // Connector credentials are stored by AppFlow and never returned; only the profile's metadata is shown.
      const p = (await c.send(new DescribeConnectorProfilesCommand({ connectorProfileNames: [name] }))).connectorProfileDetails?.[0];
      if (!p) throw httpError(`Connection not found: ${name}`, 404);
      return {
        id,
        title: name,
        subtitle: `${p.connectorType ?? ''} connection`,
        arn: p.connectorProfileArn,
        tabs: [tab('Details', { sections: [section('Connection', [['Connector', p.connectorType], ['Label', p.connectorLabel], ['Mode', p.connectionMode], ['Credentials', p.credentialsArn], ['Private connection', p.privateConnectionProvisioningState?.status], ['Created', p.createdAt], ['Updated', p.lastUpdatedAt]])] })],
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown AppFlow page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !id.startsWith('flow:')) throw httpError('Only flows can be tagged', 400);
    await af(profile, region).send(new AfTag({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !id.startsWith('flow:')) throw httpError('Only flows can be tagged', 400);
    await af(profile, region).send(new AfUntag({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('flow:'),
};
