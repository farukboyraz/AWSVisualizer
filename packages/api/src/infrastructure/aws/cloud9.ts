import {
  Cloud9Client,
  ListEnvironmentsCommand,
  DescribeEnvironmentsCommand,
  DescribeEnvironmentStatusCommand,
  DescribeEnvironmentMembershipsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-cloud9';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, mapLimited, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new Cloud9Client({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const ids = await pageAll((nextToken) => c.send(new ListEnvironmentsCommand({ nextToken })), (r) => r.environmentIds, (r) => r.nextToken);
  const chunks = Array.from({ length: Math.ceil(ids.length / 25) }, (_, i) => ids.slice(i * 25, i * 25 + 25));
  const envs = (await mapLimited(chunks, 3, (environmentIds) => c.send(new DescribeEnvironmentsCommand({ environmentIds })).then((r) => r.environments || []))).flat();
  return envs.map((e) => ({ id: `env:${e.id}`, name: e.name || e.id || '', status: e.lifecycle?.status, info: [e.type, e.connectionType, e.description].filter(Boolean).join(' · ') })).sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, envId] = splitId(id);
  if (kind !== 'env') throw httpError(`Unknown Cloud9 page: ${id}`, 400);
  const c = client(profile, region);
  const e = (await c.send(new DescribeEnvironmentsCommand({ environmentIds: [envId] }))).environments?.[0];
  if (!e) throw httpError(`Environment not found: ${envId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      status: c.send(new DescribeEnvironmentStatusCommand({ environmentId: envId })),
      members: pageAll((nextToken) => c.send(new DescribeEnvironmentMembershipsCommand({ environmentId: envId, nextToken })), (r) => r.memberships, (r) => r.nextToken),
      tags: c.send(new ListTagsForResourceCommand({ ResourceARN: e.arn })),
    },
    errors,
  );
  return {
    id,
    title: e.name || envId,
    subtitle: `${e.type ?? ''} Cloud9 environment`,
    status: parts.status?.status ?? e.lifecycle?.status,
    arn: e.arn,
    tabs: [
      tab('Details', {
        sections: [
          section(
            'Environment',
            [
              ['Name', e.name],
              ['Description', e.description],
              ['Type', e.type],
              ['Connection', e.connectionType],
              ['Status', parts.status?.status],
              ['Status message', parts.status?.message],
              ['Lifecycle', e.lifecycle?.status],
              ['Lifecycle reason', e.lifecycle?.reason],
              ['Managed credentials', e.managedCredentialsStatus],
              ['Owner', e.ownerArn],
            ],
            { note: 'AWS closed Cloud9 to new customers in July 2024; existing environments keep working.' },
          ),
        ],
      }),
      tab('Members', {
        tables: [table(['User', 'Permissions', 'Last access'], (parts.members || []).map((m) => [m.userArn, m.permissions, m.lastAccess]), { emptyMessage: 'No members' })],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

export const cloud9Adapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
};
