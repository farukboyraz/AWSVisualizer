import {
  ResourceGroupsClient,
  ListGroupsCommand,
  GetGroupCommand,
  GetGroupQueryCommand,
  GetGroupConfigurationCommand,
  ListGroupResourcesCommand,
  GetTagsCommand,
  TagCommand,
  UntagCommand,
} from '@aws-sdk/client-resource-groups';
import { ResourceGroupsTaggingAPIClient, GetResourcesCommand } from '@aws-sdk/client-resource-groups-tagging-api';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ResourceGroupsClient({ region: r, credentials: cachedCredentials(p) });
const tagging = (p: string, r: string) => new ResourceGroupsTaggingAPIClient({ region: r, credentials: cachedCredentials(p) });

const MEMBER_LIMIT = 1000;
const TAGGED_LIMIT = 2000;

/** arn:aws:ec2:region:acct:instance/i-123 → "ec2:instance". */
const arnType = (arn?: string) => {
  const p = arn?.split(':') || [];
  return p.length > 5 ? `${p[2]}:${p[5].split(/[/:]/)[0]}` : p[2];
};

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const groups = await pageAll((NextToken) => c.send(new ListGroupsCommand({ NextToken })), (r) => r.GroupIdentifiers, (r) => r.NextToken);
  return [
    { id: 'tags:', name: 'Tag Editor', group: 'Tag Editor', info: `Tagged resources and tag keys in ${region}` },
    ...groups.map((g) => ({ id: `grp:${g.GroupName}`, name: g.GroupName || '', group: 'Resource groups', info: g.GroupArn?.split(':')[2] === 'resource-groups' ? 'Resource group' : undefined })).sort((a, b) => a.name.localeCompare(b.name)),
  ];
}

async function tagEditorPage(profile: string, region: string): Promise<ResourcePage> {
  const t = tagging(profile, region);
  const resources = await pageAll((PaginationToken) => t.send(new GetResourcesCommand({ PaginationToken, ResourcesPerPage: 100 })), (r) => r.ResourceTagMappingList, (r) => r.PaginationToken || undefined, TAGGED_LIMIT);
  const keys = new Map<string, { resources: number; values: Set<string> }>();
  for (const r of resources)
    for (const tg of r.Tags || []) {
      const k = keys.get(tg.Key || '') ?? { resources: 0, values: new Set<string>() };
      k.resources++;
      k.values.add(tg.Value || '');
      keys.set(tg.Key || '', k);
    }
  const types = new Map<string, number>();
  for (const r of resources) types.set(arnType(r.ResourceARN) || '-', (types.get(arnType(r.ResourceARN) || '-') ?? 0) + 1);
  const capped = resources.length >= TAGGED_LIMIT;
  return {
    id: 'tags:',
    title: 'Tag Editor',
    subtitle: `Tagged resources in ${region}`,
    tabs: [
      tab('Tag keys', {
        sections: [section('Summary', [['Tagged resources', capped ? `${TAGGED_LIMIT}+` : resources.length], ['Distinct tag keys', keys.size], ['Resource types', types.size]], { note: 'Only resources that have at least one tag (or had one) appear here.' })],
        tables: [
          table(
            ['Tag key', 'Resources', 'Distinct values', 'Sample values'],
            [...keys.entries()].sort((a, b) => b[1].resources - a[1].resources).map(([k, v]) => [k, v.resources, v.values.size, [...v.values].slice(0, 5)]),
            { emptyMessage: 'No tags' },
          ),
        ],
      }),
      tab('Resources', {
        tables: [
          table(
            ['Resource', 'Type', 'Tags'],
            resources.map((r) => [r.ResourceARN, arnType(r.ResourceARN), (r.Tags || []).map((x) => `${x.Key}=${x.Value}`)]),
            { title: capped ? `First ${TAGGED_LIMIT} resources` : undefined, emptyMessage: 'No tagged resources' },
          ),
        ],
      }),
      tab('By type', {
        tables: [table(['Resource type', 'Tagged resources'], [...types.entries()].sort((a, b) => b[1] - a[1]), { emptyMessage: 'No tagged resources' })],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function groupPage(c: ResourceGroupsClient, id: string, name: string): Promise<ResourcePage> {
  const g = (await c.send(new GetGroupCommand({ Group: name }))).Group;
  if (!g) throw httpError(`Resource group not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      query: c.send(new GetGroupQueryCommand({ Group: name })),
      config: c.send(new GetGroupConfigurationCommand({ Group: name })),
      members: pageAll((NextToken) => c.send(new ListGroupResourcesCommand({ Group: name, NextToken })), (r) => r.Resources, (r) => r.NextToken, MEMBER_LIMIT),
      tags: c.send(new GetTagsCommand({ Arn: g.GroupArn })),
    },
    errors,
    // Tag-query groups have no configuration; configuration groups have no query.
    (err) => ['BadRequestException', 'NotFoundException'].includes((err as { name?: string })?.name || ''),
  );
  const q = parts.query?.GroupQuery?.ResourceQuery;
  let queryJson: string | undefined;
  try {
    queryJson = q?.Query ? JSON.stringify(JSON.parse(q.Query), null, 2) : undefined;
  } catch {
    queryJson = q?.Query;
  }
  const cfg = parts.config?.GroupConfiguration?.Configuration;
  return {
    id,
    title: g.Name || name,
    subtitle: g.Description || (q ? `${q.Type} group` : 'Service-configured group'),
    status: parts.config?.GroupConfiguration?.Status,
    arn: g.GroupArn,
    tabs: [
      tab('Resources', {
        tables: [
          table(
            ['Resource', 'Type', 'Status'],
            (parts.members || []).map((m) => [m.Identifier?.ResourceArn, m.Identifier?.ResourceType, m.Status?.Name]),
            { title: (parts.members?.length ?? 0) >= MEMBER_LIMIT ? `First ${MEMBER_LIMIT} resources` : `${parts.members?.length ?? 0} resources`, emptyMessage: 'No resources match' },
          ),
        ],
      }),
      tab('Details', {
        sections: [section('Group', [['Name', g.Name], ['Description', g.Description], ['Query type', q?.Type], ['Configuration types', (cfg || []).map((x) => x.Type)]])],
        tables: cfg?.length ? [table(['Configuration', 'Parameters'], cfg.map((x) => [x.Type, (x.Parameters || []).map((p) => `${p.Name}=${(p.Values || []).join(',')}`)]), { title: 'Configuration' })] : [],
      }),
      ...(queryJson ? [tab('Query', { json: queryJson })] : []),
    ],
    tags: tagMap(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, name] = splitId(id);
  if (kind === 'tags') return tagEditorPage(profile, region);
  if (kind === 'grp') return groupPage(client(profile, region), id, name);
  throw httpError(`Unknown Resource Groups page: ${id}`, 400);
}

function groupArn(id: string, arn: string) {
  if (!id.startsWith('grp:') || !arn) throw httpError('Only resource groups can be tagged here', 400);
  return arn;
}

export const resourceGroupsAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    await client(profile, region).send(new TagCommand({ Arn: groupArn(id, arn), Tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, arn, key) {
    await client(profile, region).send(new UntagCommand({ Arn: groupArn(id, arn), Keys: [key] }));
  },
  countable: (row) => row.id.startsWith('grp:'),
};
