import {
  DataZoneClient,
  ListDomainsCommand,
  GetDomainCommand,
  ListProjectsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-datazone';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new DataZoneClient({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const domains = await pageAll((nextToken) => client(profile, region).send(new ListDomainsCommand({ nextToken })), (r) => r.items, (r) => r.nextToken);
  return domains.map((d) => ({ id: `dom:${d.id}`, name: d.name || d.id || '', status: d.status, info: [d.id, d.description].filter(Boolean).join(' · ') })).sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, domainId] = splitId(id);
  if (kind !== 'dom') throw httpError(`Unknown DataZone page: ${id}`, 400);
  const c = client(profile, region);
  const d = await c.send(new GetDomainCommand({ identifier: domainId }));
  const errors: string[] = [];
  const parts = await settle(
    {
      projects: pageAll((nextToken) => c.send(new ListProjectsCommand({ domainIdentifier: domainId, nextToken })), (r) => r.items, (r) => r.nextToken, 500),
      tags: d.arn ? c.send(new ListTagsForResourceCommand({ resourceArn: d.arn })) : Promise.resolve(undefined),
    },
    errors,
  );
  return {
    id,
    title: d.name || domainId,
    subtitle: d.description || 'DataZone domain',
    status: d.status,
    arn: d.arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Domain', [['Domain ID', d.id], ['Status', d.status], ['Execution role', d.domainExecutionRole], ['KMS key', d.kmsKeyIdentifier], ['Single sign-on', d.singleSignOn?.type], ['Root domain unit', d.rootDomainUnitId], ['Created', d.createdAt], ['Updated', d.lastUpdatedAt]]),
          ...(d.portalUrl ? [{ title: 'Data portal', settings: [], copyable: [{ label: 'Portal URL', value: d.portalUrl }] }] : []),
        ],
      }),
      tab('Projects', {
        tables: [table(['Project', 'Status', 'Created by', 'Created', 'Updated', 'Description'], (parts.projects || []).map((p) => [p.name, p.projectStatus, p.createdBy, p.createdAt, p.updatedAt, p.description]), { statusColumn: 1, emptyMessage: 'No projects' })],
      }),
    ],
    tags: tagMap(parts.tags?.tags ?? d.tags),
    actions: [],
    errors,
  };
}

export const dataZoneAdapter: PageServiceAdapter = {
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
