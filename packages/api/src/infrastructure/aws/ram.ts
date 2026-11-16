import {
  RAMClient,
  GetResourceSharesCommand,
  ListResourcesCommand,
  ListPrincipalsCommand,
  ListResourceSharePermissionsCommand,
  GetResourceShareInvitationsCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type ResourceOwner,
} from '@aws-sdk/client-ram';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new RAMClient({ region: r, credentials: cachedCredentials(p) });

const owner = (kind: string): ResourceOwner => (kind === 'own' ? 'SELF' : 'OTHER-ACCOUNTS');

async function shares(c: RAMClient, resourceOwner: ResourceOwner, arns?: string[]) {
  return pageAll((nextToken) => c.send(new GetResourceSharesCommand({ resourceOwner, nextToken, resourceShareArns: arns })), (r) => r.resourceShares, (r) => r.nextToken);
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [mine, others, invitations] = await Promise.all([
    shares(c, 'SELF'),
    shares(c, 'OTHER-ACCOUNTS'),
    pageAll((nextToken) => c.send(new GetResourceShareInvitationsCommand({ nextToken })), (r) => r.resourceShareInvitations, (r) => r.nextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  const live = (s: { status?: string }) => s.status !== 'DELETED';
  return [
    ...mine.filter(live).map((s) => ({ id: `own:${s.resourceShareArn}`, name: s.name || '', group: 'Shared by me', status: s.status, info: s.allowExternalPrincipals ? 'Allows principals outside the organization' : 'Organization only' })).sort(byName),
    ...others.filter(live).map((s) => ({ id: `oth:${s.resourceShareArn}`, name: s.name || '', group: 'Shared with me', status: s.status, info: `From account ${s.owningAccountId ?? '-'}` })).sort(byName),
    ...invitations
      .filter((i) => i.status === 'PENDING')
      .map((i) => ({ id: `inv:${i.resourceShareInvitationArn}`, name: i.resourceShareName || '', group: 'Pending invitations', status: i.status, info: `From account ${i.senderAccountId ?? '-'}` })),
  ];
}

async function invitationPage(c: RAMClient, id: string, arn: string): Promise<ResourcePage> {
  const i = (await c.send(new GetResourceShareInvitationsCommand({ resourceShareInvitationArns: [arn] }))).resourceShareInvitations?.[0];
  if (!i) throw httpError(`Invitation not found: ${arn}`, 404);
  return {
    id,
    title: i.resourceShareName || arn,
    subtitle: 'Resource share invitation',
    status: i.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Invitation', [['Resource share', i.resourceShareArn], ['From account', i.senderAccountId], ['To account', i.receiverAccountId], ['Sent', i.invitationTimestamp], ['Status', i.status]], {
            note: 'Accept or reject invitations in the RAM console.',
          }),
        ],
      }),
    ],
    actions: [],
    errors: [],
  };
}

async function sharePage(c: RAMClient, id: string, kind: string, arn: string): Promise<ResourcePage> {
  const resourceOwner = owner(kind);
  const s = (await shares(c, resourceOwner, [arn]))[0];
  if (!s) throw httpError(`Resource share not found: ${arn}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      resources: pageAll((nextToken) => c.send(new ListResourcesCommand({ resourceOwner, resourceShareArns: [arn], nextToken })), (r) => r.resources, (r) => r.nextToken),
      principals: pageAll((nextToken) => c.send(new ListPrincipalsCommand({ resourceOwner, resourceShareArns: [arn], nextToken })), (r) => r.principals, (r) => r.nextToken),
      permissions: pageAll((nextToken) => c.send(new ListResourceSharePermissionsCommand({ resourceShareArn: arn, nextToken })), (r) => r.permissions, (r) => r.nextToken),
    },
    errors,
  );
  return {
    id,
    title: s.name || arn,
    subtitle: kind === 'own' ? 'Shared by me' : `Shared with me by ${s.owningAccountId ?? '-'}`,
    status: s.status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Resource share', [
            ['Name', s.name],
            ['Owner', s.owningAccountId],
            ['Status', s.status],
            ['Status message', s.statusMessage],
            ['Allow external principals', s.allowExternalPrincipals],
            ['Feature set', s.featureSet],
            ['Created', s.creationTime],
            ['Updated', s.lastUpdatedTime],
          ]),
        ],
      }),
      tab('Shared resources', {
        tables: [table(['Resource', 'Type', 'Region scope', 'Status', 'Updated'], (parts.resources || []).map((r) => [r.arn, r.type, r.resourceRegionScope, r.status, r.lastUpdatedTime]), { statusColumn: 3, emptyMessage: 'No resources' })],
      }),
      tab('Principals', {
        tables: [table(['Principal', 'External', 'Added'], (parts.principals || []).map((p) => [p.id, p.external ? 'Yes' : 'No', p.creationTime]), { emptyMessage: kind === 'own' ? 'Not shared with anyone' : 'Shared with this account' })],
      }),
      tab('Managed permissions', {
        tables: [table(['Permission', 'Resource type', 'Version', 'Default version', 'Status'], (parts.permissions || []).map((p) => [p.name, p.resourceType, p.version, p.defaultVersion, p.status]), { statusColumn: 4, emptyMessage: 'No permissions' })],
      }),
    ],
    // Only the owner can tag a share.
    tags: kind === 'own' ? (s.tags || []).map((t) => ({ key: t.key || '', value: t.value || '' })) : undefined,
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'inv') return invitationPage(c, id, arn);
  if (kind === 'own' || kind === 'oth') return sharePage(c, id, kind, arn);
  throw httpError(`Unknown RAM resource: ${id}`, 400);
}

export const ramAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    const [kind, arn] = splitId(id);
    if (kind !== 'own') throw httpError('Only your own resource shares can be tagged', 400);
    await client(profile, region).send(new TagResourceCommand({ resourceShareArn: arn, tags: [{ key, value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    const [kind, arn] = splitId(id);
    if (kind !== 'own') throw httpError('Only your own resource shares can be tagged', 400);
    await client(profile, region).send(new UntagResourceCommand({ resourceShareArn: arn, tagKeys: [key] }));
  },
  countable: (row) => !row.id.startsWith('inv:'),
};
