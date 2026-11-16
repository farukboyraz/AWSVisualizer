import {
  WorkMailClient,
  ListOrganizationsCommand,
  DescribeOrganizationCommand,
  ListUsersCommand,
  ListGroupsCommand,
  ListResourcesCommand,
  ListMailDomainsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-workmail';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** WorkMail: organizations with their users, groups, resources and mail domains. */
const client = (p: string, r: string) => new WorkMailClient(clientConfig(p, r));
const MEMBER_LIMIT = 500;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const orgs = await pageAll((NextToken) => client(profile, region).send(new ListOrganizationsCommand({ NextToken })), (r) => r.OrganizationSummaries, (r) => r.NextToken);
  return orgs.filter((o) => o.State !== 'Deleted').map((o) => ({ id: `org:${o.OrganizationId}`, name: o.Alias || o.OrganizationId || '', status: o.State, info: o.DefaultMailDomain })).sort(byName);
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, orgId] = splitId(id);
  if (kind !== 'org') throw httpError(`Unknown WorkMail page: ${id}`, 400);
  const c = client(profile, region);
  const o = await c.send(new DescribeOrganizationCommand({ OrganizationId: orgId }));
  const errors: string[] = [];
  const parts = await settle(
    {
      users: pageAll((NextToken) => c.send(new ListUsersCommand({ OrganizationId: orgId, NextToken })), (r) => r.Users, (r) => r.NextToken, MEMBER_LIMIT),
      groups: pageAll((NextToken) => c.send(new ListGroupsCommand({ OrganizationId: orgId, NextToken })), (r) => r.Groups, (r) => r.NextToken, MEMBER_LIMIT),
      resources: pageAll((NextToken) => c.send(new ListResourcesCommand({ OrganizationId: orgId, NextToken })), (r) => r.Resources, (r) => r.NextToken),
      domains: pageAll((NextToken) => c.send(new ListMailDomainsCommand({ OrganizationId: orgId, NextToken })), (r) => r.MailDomains, (r) => r.NextToken),
      tags: o.ARN ? c.send(new ListTagsForResourceCommand({ ResourceARN: o.ARN })) : Promise.resolve(undefined),
    },
    errors,
  );
  // System users (e.g. the migration admin) have no e-mail; deleted entries are hidden.
  const users = (parts.users || []).filter((u) => u.State !== 'DELETED');
  return {
    id,
    title: o.Alias || orgId,
    subtitle: 'WorkMail organization',
    status: o.State,
    arn: o.ARN,
    tabs: [
      tab('Details', {
        sections: [section('Organization', [['Organization ID', o.OrganizationId], ['State', o.State], ['Default domain', o.DefaultMailDomain], ['Directory', o.DirectoryType && `${o.DirectoryType} ${o.DirectoryId ?? ''}`], ['Interoperability (Exchange)', o.InteroperabilityEnabled], ['Created', o.CompletedDate], ['Error', o.ErrorMessage]])],
        tables: [table(['Domain', 'Default'], (parts.domains || []).map((d) => [d.DomainName, d.DefaultDomain]), { title: 'Mail domains', emptyMessage: 'No mail domains' })],
      }),
      tab('Users', {
        tables: [table(['User', 'Display name', 'E-mail', 'Role', 'State', 'Enabled'], users.map((u) => [u.Name, u.DisplayName, u.Email, u.UserRole, u.State, u.EnabledDate]), { statusColumn: 4, title: users.length >= MEMBER_LIMIT ? `First ${MEMBER_LIMIT} users` : `${users.length} users`, emptyMessage: 'No users' })],
      }),
      tab('Groups & resources', {
        tables: [
          table(['Group', 'E-mail', 'State'], (parts.groups || []).filter((g) => g.State !== 'DELETED').map((g) => [g.Name, g.Email, g.State]), { title: 'Groups', statusColumn: 2, emptyMessage: 'No groups' }),
          table(['Resource', 'Type', 'E-mail', 'State'], (parts.resources || []).filter((r) => r.State !== 'DELETED').map((r) => [r.Name, r.Type, r.Email, r.State]), { title: 'Rooms & equipment', statusColumn: 3, emptyMessage: 'No resources' }),
        ],
      }),
    ],
    tags: tagList(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

export const workMailAdapter: PageServiceAdapter = {
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
