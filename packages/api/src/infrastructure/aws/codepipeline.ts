import {
  CodePipelineClient,
  ListPipelinesCommand,
  GetPipelineCommand,
  GetPipelineStateCommand,
  ListPipelineExecutionsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type ActionDeclaration,
} from '@aws-sdk/client-codepipeline';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new CodePipelineClient({ region: r, credentials: cachedCredentials(p) });

const EXECUTION_LIMIT = 25;
/** Action configuration keys whose values are never shown (OAuthToken, webhook secrets…). */
const SECRET_KEY = /token|secret|password|credential|private.?key|apikey/i;

const actionType = (a: ActionDeclaration) => `${a.actionTypeId?.category ?? ''}: ${a.actionTypeId?.provider ?? ''}`;
const config = (a: ActionDeclaration) =>
  Object.entries(a.configuration || {})
    .map(([k, v]) => `${k}=${SECRET_KEY.test(k) ? '••••' : v}`)
    .join(', ');

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const pipelines = await pageAll((nextToken) => c.send(new ListPipelinesCommand({ nextToken })), (r) => r.pipelines, (r) => r.nextToken);
  // Latest execution status per pipeline (one cheap call each).
  const latest = await mapLimited(pipelines, 5, (p) =>
    c.send(new ListPipelineExecutionsCommand({ pipelineName: p.name, maxResults: 1 })).then((r) => r.pipelineExecutionSummaries?.[0]).catch(() => undefined),
  );
  return pipelines
    .map((p, i) => ({
      id: `pl:${p.name}`,
      name: p.name || '',
      status: latest[i]?.status,
      info: [p.pipelineType, p.executionMode, latest[i]?.lastUpdateTime && `last run ${latest[i]!.lastUpdateTime!.toISOString().slice(0, 16).replace('T', ' ')}`].filter(Boolean).join(' · '),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, name] = splitId(id);
  if (kind !== 'pl') throw httpError(`Unknown CodePipeline page: ${id}`, 400);
  const c = client(profile, region);
  const got = await c.send(new GetPipelineCommand({ name }));
  const p = got.pipeline;
  if (!p) throw httpError(`Pipeline not found: ${name}`, 404);
  const arn = got.metadata?.pipelineArn;
  const errors: string[] = [];
  const parts = await settle(
    {
      state: c.send(new GetPipelineStateCommand({ name })),
      executions: c.send(new ListPipelineExecutionsCommand({ pipelineName: name, maxResults: EXECUTION_LIMIT })),
      tags: arn ? c.send(new ListTagsForResourceCommand({ resourceArn: arn })) : Promise.resolve(undefined),
    },
    errors,
  );
  const states = new Map((parts.state?.stageStates || []).map((s) => [s.stageName, s]));
  const runs = parts.executions?.pipelineExecutionSummaries || [];
  // The action token is an approval secret - only status / summary / links are used.
  const stageRows = (p.stages || []).flatMap((stage) => {
    const st = states.get(stage.name);
    const actions = new Map((st?.actionStates || []).map((a) => [a.actionName, a]));
    return (stage.actions || []).map((a, i) => {
      const s = actions.get(a.name)?.latestExecution;
      return [i === 0 ? stage.name : '', a.name, actionType(a), s?.status ?? (i === 0 ? st?.latestExecution?.status : undefined), s?.summary ?? s?.errorDetails?.message, s?.lastStatusChange, a.runOrder];
    });
  });
  return {
    id,
    title: name,
    subtitle: `${p.pipelineType ?? 'V1'} pipeline · ${p.stages?.length ?? 0} stages`,
    status: runs[0]?.status,
    arn,
    tabs: [
      tab('Stages', {
        tables: [table(['Stage', 'Action', 'Type', 'Status', 'Summary', 'Changed', 'Run order'], stageRows, { statusColumn: 3, emptyMessage: 'No stages' })],
      }),
      tab('Execution history', {
        tables: [
          table(
            ['Execution', 'Status', 'Started', 'Updated', 'Trigger', 'Source revision', 'Summary'],
            runs.map((r) => [r.pipelineExecutionId?.slice(0, 8), r.status, r.startTime, r.lastUpdateTime, r.trigger?.triggerType, (r.sourceRevisions || []).map((s) => `${s.actionName}: ${s.revisionSummary ?? s.revisionId?.slice(0, 12) ?? ''}`).join('; '), r.statusSummary]),
            { statusColumn: 1, title: `Last ${EXECUTION_LIMIT} executions`, emptyMessage: 'Never run' },
          ),
        ],
      }),
      tab('Settings', {
        sections: [
          section('Pipeline', [
            ['Name', p.name],
            ['Type', p.pipelineType],
            ['Execution mode', p.executionMode],
            ['Version', p.version],
            ['Service role', p.roleArn],
            ['Artifact store', p.artifactStore ? `${p.artifactStore.type} ${p.artifactStore.location}` : Object.entries(p.artifactStores || {}).map(([r, s]) => `${r}: ${s.location}`)],
            ['Created', got.metadata?.created],
            ['Updated', got.metadata?.updated],
          ]),
        ],
        tables: [
          table(['Stage', 'Action', 'Type', 'Configuration', 'Input', 'Output'], (p.stages || []).flatMap((s) => (s.actions || []).map((a) => [s.name, a.name, actionType(a), config(a), (a.inputArtifacts || []).map((x) => x.name), (a.outputArtifacts || []).map((x) => x.name)])), { title: 'Actions' }),
          table(['Variable', 'Default', 'Description'], (p.variables || []).map((v) => [v.name, v.defaultValue, v.description]), { title: 'Variables', emptyMessage: 'No variables' }),
          table(['Provider', 'Source action', 'Push filters'], (p.triggers || []).map((t) => [t.providerType, t.gitConfiguration?.sourceActionName, (t.gitConfiguration?.push || []).map((x) => [...(x.branches?.includes || []), ...(x.tags?.includes || [])].join(', '))]), { title: 'Triggers', emptyMessage: 'No triggers (V1 change detection)' }),
        ],
      }),
    ],
    tags: tagList(parts.tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))),
    actions: [],
    errors,
  };
}

export const codePipelineAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ key, value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
};
