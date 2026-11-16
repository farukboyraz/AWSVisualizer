import {
  ApplicationDiscoveryServiceClient,
  GetDiscoverySummaryCommand,
  DescribeAgentsCommand,
  DescribeImportTasksCommand,
  DescribeContinuousExportsCommand,
} from '@aws-sdk/client-application-discovery-service';
import { section, table, tab, httpError, pageAll, clientConfig } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const errName = (err: unknown) => (err as { name?: string })?.name || '';
/** Home-region services (Migration Hub, Discovery) and not-initialized services answer with these outside their setup. */
const notSetUp = (err: unknown) =>
  ['HomeRegionNotSetException', 'AccessDeniedException', 'UninitializedAccountException', 'InvalidInputException', 'AuthorizationErrorException'].includes(errName(err)) ||
  /home region|not (been )?initialized|not subscribed/i.test((err as { message?: string })?.message || '');

/** Application Discovery Service. */
const ads = (p: string, r: string) => new ApplicationDiscoveryServiceClient(clientConfig(p, r));
const DISCOVERY_PAGES: Record<string, { name: string; info: string }> = {
  summary: { name: 'Discovery summary', info: 'Servers, applications and collectors' },
  agents: { name: 'Agents & collectors', info: 'Discovery agents and Agentless Collectors' },
  imports: { name: 'Import tasks', info: 'Imported server inventories' },
  exports: { name: 'Continuous exports', info: 'Data exported to Athena / S3' },
};

export const discoveryAdapter: PageServiceAdapter = {
  async list(profile, region) {
    try {
      await ads(profile, region).send(new GetDiscoverySummaryCommand({}));
    } catch (err) {
      if (notSetUp(err)) return [];
      throw err;
    }
    return Object.entries(DISCOVERY_PAGES).map(([k, p]) => ({ id: `${k}:`, name: p.name, info: p.info }));
  },
  async detail(profile, region, id) {
    const c = ads(profile, region);
    const [kind] = splitId(id);
    const p = DISCOVERY_PAGES[kind];
    if (!p) throw httpError(`Unknown Discovery page: ${id}`, 400);
    const base = { id, title: p.name, subtitle: 'Application Discovery Service', actions: [], errors: [] as string[] };
    if (kind === 'summary') {
      const s = await c.send(new GetDiscoverySummaryCommand({}));
      const agent = (x?: { activeAgents?: number; healthyAgents?: number; unhealthyAgents?: number; totalAgents?: number }) => (x ? `${x.totalAgents ?? 0} total · ${x.healthyAgents ?? 0} healthy · ${x.unhealthyAgents ?? 0} unhealthy` : undefined);
      return {
        ...base,
        tabs: [
          tab('Summary', {
            sections: [
              section('Inventory', [['Servers', s.servers], ['Applications', s.applications], ['Servers mapped to applications', s.serversMappedToApplications], ['Servers mapped by tags', s.serversMappedtoTags]]),
              section('Collectors', [['Discovery agents', agent(s.agentSummary)], ['Agentless collectors', s.agentlessCollectorSummary ? `${s.agentlessCollectorSummary.totalAgentlessCollectors ?? 0} total` : undefined], ['Migration evaluator', s.meCollectorSummary ? `${s.meCollectorSummary.totalMeCollectors ?? 0} total` : undefined]], {
                note: 'Discovery only answers in the Migration Hub home region.',
              }),
            ],
          }),
        ],
      };
    }
    if (kind === 'agents') {
      const agents = await pageAll((nextToken) => c.send(new DescribeAgentsCommand({ nextToken })), (r) => r.agentsInfo, (r) => r.nextToken);
      return { ...base, tabs: [tab('Agents', { tables: [table(['Agent', 'Host', 'Type', 'Health', 'Collection', 'Version', 'Last ping'], agents.map((a) => [a.agentId, a.hostName, a.agentType, a.health, a.collectionStatus, a.version, a.lastHealthPingTime]), { statusColumn: 3, emptyMessage: 'No agents' })] })] };
    }
    if (kind === 'imports') {
      const tasks = await pageAll((nextToken) => c.send(new DescribeImportTasksCommand({ nextToken })), (r) => r.tasks, (r) => r.nextToken);
      return { ...base, tabs: [tab('Imports', { tables: [table(['Import', 'Status', 'Requested', 'Completed', 'Servers ok / failed', 'Apps ok / failed'], tasks.map((t) => [t.name, t.status, t.importRequestTime, t.importCompletionTime, `${t.serverImportSuccess ?? 0} / ${t.serverImportFailure ?? 0}`, `${t.applicationImportSuccess ?? 0} / ${t.applicationImportFailure ?? 0}`]), { statusColumn: 1, emptyMessage: 'No imports' })] })] };
    }
    const exports = await pageAll((nextToken) => c.send(new DescribeContinuousExportsCommand({ nextToken })), (r) => r.descriptions, (r) => r.nextToken);
    return { ...base, tabs: [tab('Exports', { tables: [table(['Export', 'Status', 'Bucket', 'Source', 'Started', 'Detail'], exports.map((e) => [e.exportId, e.status, e.s3Bucket, e.dataSource, e.startTime, e.statusDetail]), { statusColumn: 1, emptyMessage: 'No continuous exports' })] })] };
  },
  uncounted: true,
};
