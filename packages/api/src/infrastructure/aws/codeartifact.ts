import {
  CodeartifactClient,
  ListDomainsCommand,
  DescribeDomainCommand,
  GetDomainPermissionsPolicyCommand,
  ListRepositoriesCommand,
  DescribeRepositoryCommand,
  GetRepositoryPermissionsPolicyCommand,
  ListPackagesCommand,
  GetRepositoryEndpointCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-codeartifact';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, policyJson, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new CodeartifactClient({ region: r, credentials: cachedCredentials(p) });

const PACKAGE_LIMIT = 500;
const FORMATS = ['npm', 'pypi', 'maven', 'nuget', 'generic', 'ruby', 'swift', 'cargo'] as const;
const noPolicy = (err: unknown) => (err as { name?: string })?.name === 'ResourceNotFoundException';
const size = (b?: number) => (b === undefined ? undefined : b > 1e9 ? `${(b / 1e9).toFixed(2)} GB` : b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.round(b / 1e3)} KB`);

/** Repository ids carry the domain and its owner: `repo:<domain>|<owner>|<name>`. */
const parseRepo = (rest: string) => {
  const [domain, domainOwner, repository] = rest.split('|');
  if (!domain || !domainOwner || !repository) throw httpError(`Bad repository id: ${rest}`, 400);
  return { domain, domainOwner, repository };
};

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [domains, repos] = await Promise.all([
    pageAll((nextToken) => c.send(new ListDomainsCommand({ nextToken })), (r) => r.domains, (r) => r.nextToken),
    pageAll((nextToken) => c.send(new ListRepositoriesCommand({ nextToken })), (r) => r.repositories, (r) => r.nextToken),
  ]);
  return [
    ...domains.map((d) => ({ id: `dom:${d.name}|${d.owner}`, name: d.name || '', group: 'Domains', status: d.status, info: `owner ${d.owner ?? '-'}` })),
    ...repos
      .map((r) => ({ id: `repo:${r.domainName}|${r.domainOwner}|${r.name}`, name: r.name || '', group: 'Repositories', info: [`domain ${r.domainName}`, r.description].filter(Boolean).join(' · ') }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function domainRepositories(c: CodeartifactClient, domain: string, domainOwner: string) {
  const all = await pageAll((nextToken) => c.send(new ListRepositoriesCommand({ nextToken })), (r) => r.repositories, (r) => r.nextToken);
  return all.filter((r) => r.domainName === domain && r.domainOwner === domainOwner);
}

async function domainPage(c: CodeartifactClient, id: string, rest: string): Promise<ResourcePage> {
  const [domain, domainOwner] = rest.split('|');
  const d = (await c.send(new DescribeDomainCommand({ domain, domainOwner }))).domain;
  if (!d) throw httpError(`Domain not found: ${domain}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      repos: domainRepositories(c, domain, domainOwner),
      policy: c.send(new GetDomainPermissionsPolicyCommand({ domain, domainOwner })),
      tags: d.arn ? c.send(new ListTagsForResourceCommand({ resourceArn: d.arn })) : Promise.resolve(undefined),
    },
    errors,
    noPolicy,
  );
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [section('Domain', [['Name', d.name], ['Owner', d.owner], ['Status', d.status], ['Repositories', d.repositoryCount], ['Stored assets', size(d.assetSizeBytes)], ['Encryption key', d.encryptionKey], ['Created', d.createdTime]])],
      tables: [table(['Repository', 'Description', 'Created'], (parts.repos || []).map((r) => [r.name, r.description, r.createdTime]), { title: 'Repositories', emptyMessage: 'No repositories' })],
    }),
  ];
  const policy = policyJson(parts.policy?.policy?.document);
  if (policy) tabs.push(tab('Domain policy', { json: policy }));
  return { id, title: d.name || domain, subtitle: 'CodeArtifact domain', status: d.status, arn: d.arn, tabs, tags: tagList(parts.tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))), actions: [], errors };
}

async function repoPage(c: CodeartifactClient, id: string, rest: string): Promise<ResourcePage> {
  const { domain, domainOwner, repository } = parseRepo(rest);
  const r = (await c.send(new DescribeRepositoryCommand({ domain, domainOwner, repository }))).repository;
  if (!r) throw httpError(`Repository not found: ${repository}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      packages: pageAll((nextToken) => c.send(new ListPackagesCommand({ domain, domainOwner, repository, nextToken })), (x) => x.packages, (x) => x.nextToken, PACKAGE_LIMIT),
      policy: c.send(new GetRepositoryPermissionsPolicyCommand({ domain, domainOwner, repository })),
      tags: r.arn ? c.send(new ListTagsForResourceCommand({ resourceArn: r.arn })) : Promise.resolve(undefined),
    },
    errors,
    noPolicy,
  );
  // Endpoints only for formats the repository actually holds (one call each).
  const formats = [...new Set((parts.packages || []).map((p) => p.format).filter(Boolean))] as (typeof FORMATS)[number][];
  const endpoints = await mapLimited(formats, 4, (format) => c.send(new GetRepositoryEndpointCommand({ domain, domainOwner, repository, format })).then((x) => x.repositoryEndpoint).catch(() => undefined));
  const pkgs = parts.packages || [];
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Repository', [['Name', r.name], ['Domain', `${r.domainName} (owner ${r.domainOwner})`], ['Administrator', r.administratorAccount], ['Description', r.description], ['Upstreams', (r.upstreams || []).map((u) => u.repositoryName)], ['External connections', (r.externalConnections || []).map((x) => `${x.externalConnectionName} (${x.status})`)], ['Created', r.createdTime]]),
        { title: 'Endpoints', settings: [], copyable: formats.map((f, i) => ({ label: f, value: endpoints[i] || '-' })) },
      ].filter((s) => s.settings.length || ('copyable' in s && s.copyable?.length)),
    }),
    tab('Packages', {
      tables: [
        table(['Package', 'Namespace', 'Format', 'Publish', 'Upstream'], pkgs.map((p) => [p.package, p.namespace, p.format, p.originConfiguration?.restrictions?.publish, p.originConfiguration?.restrictions?.upstream]), {
          title: pkgs.length >= PACKAGE_LIMIT ? `First ${PACKAGE_LIMIT} packages` : `${pkgs.length} packages`,
          emptyMessage: 'No packages',
        }),
      ],
    }),
  ];
  const policy = policyJson(parts.policy?.policy?.document);
  if (policy) tabs.push(tab('Repository policy', { json: policy }));
  return { id, title: r.name || repository, subtitle: `Repository in ${domain}`, arn: r.arn, tabs, tags: tagList(parts.tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))), actions: [], errors };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'dom') return domainPage(c, id, rest);
  if (kind === 'repo') return repoPage(c, id, rest);
  throw httpError(`Unknown CodeArtifact page: ${id}`, 400);
}

export const codeArtifactAdapter: PageServiceAdapter = {
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
  countable: (row) => row.id.startsWith('repo:'),
};
