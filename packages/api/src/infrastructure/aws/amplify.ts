import {
  AmplifyClient,
  ListAppsCommand,
  GetAppCommand,
  ListBranchesCommand,
  ListJobsCommand,
  ListDomainAssociationsCommand,
  ListWebhooksCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-amplify';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Amplify Hosting: apps with branches, recent builds, domains and webhooks. */
const client = (p: string, r: string) => new AmplifyClient(clientConfig(p, r));
/** Environment variables with these names are shown masked; basic-auth credentials are never used. */
const SECRET_KEY = /pass(word)?|secret|token|credential|private.?key|api.?key|\bkey\b/i;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const apps = await pageAll((nextToken) => client(profile, region).send(new ListAppsCommand({ nextToken })), (r) => r.apps, (r) => r.nextToken);
  return apps.map((a) => ({ id: `app:${a.appId}`, name: a.name || a.appId || '', info: [a.platform, a.repository?.replace(/^https?:\/\//, ''), a.productionBranch?.status && `production ${a.productionBranch.status}`].filter(Boolean).join(' · '), status: a.productionBranch?.status })).sort(byName);
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, appId] = splitId(id);
  if (kind !== 'app') throw httpError(`Unknown Amplify page: ${id}`, 400);
  const c = client(profile, region);
  const a = (await c.send(new GetAppCommand({ appId }))).app;
  if (!a) throw httpError(`App not found: ${appId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      branches: pageAll((nextToken) => c.send(new ListBranchesCommand({ appId, nextToken })), (r) => r.branches, (r) => r.nextToken),
      domains: pageAll((nextToken) => c.send(new ListDomainAssociationsCommand({ appId, nextToken })), (r) => r.domainAssociations, (r) => r.nextToken),
      webhooks: pageAll((nextToken) => c.send(new ListWebhooksCommand({ appId, nextToken })), (r) => r.webhooks, (r) => r.nextToken),
    },
    errors,
  );
  const branches = parts.branches || [];
  const jobs = (await mapLimited(branches.slice(0, 10), 4, (b) => c.send(new ListJobsCommand({ appId, branchName: b.branchName, maxResults: 5 })).then((r) => (r.jobSummaries || []).map((j) => ({ ...j, branch: b.branchName }))).catch(() => []))).flat().sort((x, y) => (y.startTime?.getTime() ?? 0) - (x.startTime?.getTime() ?? 0));
  const env = (vars?: Record<string, string>) => Object.entries(vars || {}).map(([k, v]) => [k, SECRET_KEY.test(k) ? '•••• (hidden)' : v]);
  return {
    id,
    title: a.name || appId,
    subtitle: `Amplify ${a.platform ?? ''} app`,
    arn: a.appArn,
    tabs: [
      tab('Details', {
        sections: [
          section('App', [['App ID', a.appId], ['Platform', a.platform], ['Repository', a.repository], ['Default domain', a.defaultDomain], ['Production branch', a.productionBranch?.branchName], ['Auto branch creation', a.enableAutoBranchCreation], ['Branch auto-build', a.enableBranchAutoBuild], ['Basic auth', a.enableBasicAuth], ['Service role', a.iamServiceRoleArn], ['Created', a.createTime], ['Updated', a.updateTime]]),
        ],
        tables: [table(['Variable', 'Value'], env(a.environmentVariables), { title: 'Environment variables', emptyMessage: 'None' })],
      }),
      tab('Branches', {
        tables: [table(['Branch', 'Stage', 'Framework', 'Auto build', 'Basic auth', 'Updated'], branches.map((b) => [b.branchName, b.stage, b.framework, b.enableAutoBuild, b.enableBasicAuth, b.updateTime]), { emptyMessage: 'No branches' })],
      }),
      tab('Builds', {
        tables: [table(['Branch', 'Job', 'Type', 'Status', 'Started', 'Ended', 'Commit'], jobs.slice(0, 30).map((j) => [j.branch, j.jobId, j.jobType, j.status, j.startTime, j.endTime, `${j.commitId?.slice(0, 7) ?? ''} ${j.commitMessage?.split('\n')[0] ?? ''}`.trim()]), { statusColumn: 3, title: 'Most recent builds (5 per branch)', emptyMessage: 'No builds' })],
      }),
      tab('Domains', {
        tables: [
          table(['Domain', 'Status', 'Sub-domains', 'Reason'], (parts.domains || []).map((d) => [d.domainName, d.domainStatus, (d.subDomains || []).map((s) => `${s.subDomainSetting?.prefix || '(root)'} → ${s.subDomainSetting?.branchName}`), d.statusReason]), { statusColumn: 1, emptyMessage: 'No custom domains' }),
          table(['Webhook', 'Branch', 'URL'], (parts.webhooks || []).map((w) => [w.webhookId, w.branchName, w.webhookUrl]), { title: 'Webhooks', emptyMessage: 'No webhooks' }),
        ],
      }),
    ],
    tags: tagMap(a.tags),
    actions: [],
    errors,
  };
}

export const amplifyAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
};
