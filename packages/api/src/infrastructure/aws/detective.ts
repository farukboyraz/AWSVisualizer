import {
  DetectiveClient,
  ListGraphsCommand,
  ListMembersCommand,
  ListDatasourcePackagesCommand,
  ListOrganizationAdminAccountsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-detective';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new DetectiveClient({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const graphs = await pageAll((NextToken) => c.send(new ListGraphsCommand({ NextToken })), (r) => r.GraphList, (r) => r.NextToken);
  return graphs.map((g) => ({ id: g.Arn || '', name: `Behavior graph ${g.Arn?.split('/').pop()?.slice(0, 8) ?? ''}…`, status: 'ACTIVE', info: `Created ${g.CreatedTime?.toISOString().slice(0, 10) ?? '-'}` }));
}

async function detail(profile: string, region: string, arn: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const g = (await pageAll((NextToken) => c.send(new ListGraphsCommand({ NextToken })), (r) => r.GraphList, (r) => r.NextToken)).find((x) => x.Arn === arn);
  if (!g) throw httpError(`Behavior graph not found: ${arn}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      members: pageAll((NextToken) => c.send(new ListMembersCommand({ GraphArn: arn, NextToken })), (r) => r.MemberDetails, (r) => r.NextToken),
      packages: c.send(new ListDatasourcePackagesCommand({ GraphArn: arn })),
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
      admins: pageAll((NextToken) => c.send(new ListOrganizationAdminAccountsCommand({ NextToken })), (r) => r.Administrators, (r) => r.NextToken),
    },
    errors,
    // Only the organization's management account may list delegated admins.
    (err) => (err as { name?: string })?.name === 'AccessDeniedException' || (err as { name?: string })?.name === 'ValidationException',
  );
  const pkgs = Object.entries(parts.packages?.DatasourcePackages || {});
  return {
    id: arn,
    title: 'Behavior graph',
    subtitle: arn.split('/').pop(),
    status: 'ACTIVE',
    arn,
    tabs: [
      tab('Details', {
        sections: [section('Behavior graph', [['Graph ARN', arn], ['Created', g.CreatedTime], ['Member accounts', parts.members?.length], ['Delegated administrators', (parts.admins || []).map((a) => a.AccountId)]])],
      }),
      tab('Source packages', {
        tables: [
          table(
            ['Package', 'Status', 'Ingestion started'],
            pkgs.map(([name, p]) => [name, p.DatasourcePackageIngestState, p.LastIngestStateChange?.STARTED?.Timestamp]),
            { statusColumn: 1, emptyMessage: 'No source packages' },
          ),
        ],
      }),
      tab('Accounts', {
        tables: [
          table(
            ['Account', 'Email', 'Status', 'Disabled reason', 'Invitation type', 'Invited', 'Updated'],
            (parts.members || []).map((m) => [m.AccountId, m.EmailAddress, m.Status, m.DisabledReason, m.InvitationType, m.InvitedTime, m.UpdatedTime]),
            { statusColumn: 2, emptyMessage: 'No member accounts' },
          ),
        ],
      }),
    ],
    tags: tagMap(parts.tags?.Tags),
    actions: [],
    errors,
  };
}

export const detectiveAdapter: PageServiceAdapter = singleKind('graph', {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: id, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: id, TagKeys: [key] }));
  },
});
