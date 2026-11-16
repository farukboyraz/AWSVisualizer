import {
  IAMClient,
  ListUsersCommand,
  ListRolesCommand,
  ListGroupsCommand,
  ListPoliciesCommand,
  GetUserCommand,
  GetRoleCommand,
  GetGroupCommand,
  GetPolicyCommand,
  GetPolicyVersionCommand,
  ListPolicyVersionsCommand,
  ListEntitiesForPolicyCommand,
  ListAttachedUserPoliciesCommand,
  ListAttachedRolePoliciesCommand,
  ListAttachedGroupPoliciesCommand,
  ListUserPoliciesCommand,
  ListRolePoliciesCommand,
  ListGroupPoliciesCommand,
  GetUserPolicyCommand,
  GetRolePolicyCommand,
  GetGroupPolicyCommand,
  ListGroupsForUserCommand,
  ListAccessKeysCommand,
  GetAccessKeyLastUsedCommand,
  ListMFADevicesCommand,
  ListInstanceProfilesForRoleCommand,
  ListUserTagsCommand,
  ListRoleTagsCommand,
  ListPolicyTagsCommand,
  TagUserCommand,
  UntagUserCommand,
  TagRoleCommand,
  UntagRoleCommand,
  TagPolicyCommand,
  UntagPolicyCommand,
  GetLoginProfileCommand,
  type AttachedPolicy,
} from '@aws-sdk/client-iam';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError, pageAll, policyJson, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** IAM is global; its API answers in us-east-1. */
const client = (p: string) => new IAMClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

const marker = (r: { IsTruncated?: boolean; Marker?: string }) => (r.IsTruncated ? r.Marker : undefined);

async function list(profile: string): Promise<PageSummary[]> {
  const c = client(profile);
  const [users, roles, groups, policies] = await Promise.all([
    pageAll((Marker) => c.send(new ListUsersCommand({ Marker })), (r) => r.Users, marker),
    pageAll((Marker) => c.send(new ListRolesCommand({ Marker })), (r) => r.Roles, marker),
    pageAll((Marker) => c.send(new ListGroupsCommand({ Marker })), (r) => r.Groups, marker),
    pageAll((Marker) => c.send(new ListPoliciesCommand({ Marker, Scope: 'Local' })), (r) => r.Policies, marker),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...users.map((u) => ({ id: `user:${u.UserName}`, name: u.UserName || '', group: 'Users', info: [u.Path !== '/' ? u.Path : undefined, u.PasswordLastUsed ? `console sign-in ${u.PasswordLastUsed.toISOString().slice(0, 10)}` : 'no console sign-in'].filter(Boolean).join(' · ') })).sort(byName),
    ...roles.map((r) => ({ id: `role:${r.RoleName}`, name: r.RoleName || '', group: 'Roles', info: r.Description || r.Path })).sort(byName),
    ...groups.map((g) => ({ id: `group:${g.GroupName}`, name: g.GroupName || '', group: 'Groups', info: g.Path })).sort(byName),
    ...policies.map((p) => ({ id: `policy:${p.Arn}`, name: p.PolicyName || '', group: 'Customer managed policies', info: `${p.AttachmentCount ?? 0} attachments` })).sort(byName),
  ];
}

const policyTable = (attached: AttachedPolicy[] | undefined, inline: string[] | undefined) =>
  table(
    ['Policy', 'Type', 'ARN'],
    [...(attached || []).map((p) => [p.PolicyName, p.PolicyArn?.startsWith('arn:aws:iam::aws:') ? 'AWS managed' : 'Customer managed', p.PolicyArn]), ...(inline || []).map((n) => [n, 'Inline', '-'])],
    { title: 'Permissions policies', emptyMessage: 'No policies attached' },
  );

/** All inline policy documents as one `{ name: document }` JSON. */
async function inlineDocs(names: string[] | undefined, get: (name: string) => Promise<string | undefined>, errors: string[]): Promise<string | undefined> {
  if (!names?.length) return undefined;
  const docs: Record<string, unknown> = {};
  await mapLimited(names, 5, async (n) => {
    try {
      const text = policyJson(await get(n));
      docs[n] = text ? JSON.parse(text) : null;
    } catch (err) {
      errors.push(`Inline policy ${n}: ${err instanceof Error ? err.message : err}`);
    }
  });
  return JSON.stringify(docs, null, 2);
}

async function userPage(c: IAMClient, id: string, name: string): Promise<ResourcePage> {
  const u = (await c.send(new GetUserCommand({ UserName: name }))).User;
  if (!u) throw httpError(`User not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      attached: pageAll((Marker) => c.send(new ListAttachedUserPoliciesCommand({ UserName: name, Marker })), (r) => r.AttachedPolicies, marker),
      inline: pageAll((Marker) => c.send(new ListUserPoliciesCommand({ UserName: name, Marker })), (r) => r.PolicyNames, marker),
      groups: pageAll((Marker) => c.send(new ListGroupsForUserCommand({ UserName: name, Marker })), (r) => r.Groups, marker),
      keys: pageAll((Marker) => c.send(new ListAccessKeysCommand({ UserName: name, Marker })), (r) => r.AccessKeyMetadata, marker),
      mfa: pageAll((Marker) => c.send(new ListMFADevicesCommand({ UserName: name, Marker })), (r) => r.MFADevices, marker),
      tags: pageAll((Marker) => c.send(new ListUserTagsCommand({ UserName: name, Marker })), (r) => r.Tags, marker),
      // NoSuchEntity just means the user has no console password.
      login: c.send(new GetLoginProfileCommand({ UserName: name })).catch((err) => (err?.name === 'NoSuchEntityException' ? undefined : Promise.reject(err))),
    },
    errors,
  );
  const lastUsed = await mapLimited(parts.keys || [], 5, (k) =>
    c
      .send(new GetAccessKeyLastUsedCommand({ AccessKeyId: k.AccessKeyId }))
      .then((r) => r.AccessKeyLastUsed)
      .catch(() => undefined),
  );
  const inline = await inlineDocs(parts.inline, async (n) => (await c.send(new GetUserPolicyCommand({ UserName: name, PolicyName: n }))).PolicyDocument, errors);
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Summary', [
          ['User name', u.UserName],
          ['User ID', u.UserId],
          ['Path', u.Path],
          ['Created', u.CreateDate],
          ['Console access', parts.login ? 'Enabled' : 'Disabled'],
          ['Password reset required', parts.login?.LoginProfile?.PasswordResetRequired],
          ['Console last sign-in', u.PasswordLastUsed ?? 'Never'],
          ['Permissions boundary', u.PermissionsBoundary?.PermissionsBoundaryArn],
        ]),
      ],
    }),
    tab('Permissions', {
      tables: [
        policyTable(parts.attached, parts.inline),
        table(['Group', 'ARN', 'Created'], (parts.groups || []).map((g) => [g.GroupName, g.Arn, g.CreateDate]), { title: 'Groups', emptyMessage: 'Not in any group' }),
      ],
    }),
    tab('Security credentials', {
      tables: [
        table(
          ['Access key', 'Status', 'Created', 'Last used', 'Last service', 'Last region'],
          (parts.keys || []).map((k, i) => [k.AccessKeyId, k.Status, k.CreateDate, lastUsed[i]?.LastUsedDate ?? 'Never', lastUsed[i]?.ServiceName, lastUsed[i]?.Region]),
          { title: 'Access keys', statusColumn: 1, emptyMessage: 'No access keys' },
        ),
        table(['MFA device', 'Enabled'], (parts.mfa || []).map((m) => [m.SerialNumber, m.EnableDate]), { title: 'MFA devices', emptyMessage: 'No MFA devices' }),
      ],
    }),
  ];
  if (inline) tabs.push(tab('Inline policies', { json: inline }));
  return { id, title: name, subtitle: 'IAM user', arn: u.Arn, tabs, tags: tagList(parts.tags), actions: [], errors };
}

async function rolePage(c: IAMClient, id: string, name: string): Promise<ResourcePage> {
  const r = (await c.send(new GetRoleCommand({ RoleName: name }))).Role;
  if (!r) throw httpError(`Role not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      attached: pageAll((Marker) => c.send(new ListAttachedRolePoliciesCommand({ RoleName: name, Marker })), (x) => x.AttachedPolicies, marker),
      inline: pageAll((Marker) => c.send(new ListRolePoliciesCommand({ RoleName: name, Marker })), (x) => x.PolicyNames, marker),
      profiles: pageAll((Marker) => c.send(new ListInstanceProfilesForRoleCommand({ RoleName: name, Marker })), (x) => x.InstanceProfiles, marker),
      tags: pageAll((Marker) => c.send(new ListRoleTagsCommand({ RoleName: name, Marker })), (x) => x.Tags, marker),
    },
    errors,
  );
  const inline = await inlineDocs(parts.inline, async (n) => (await c.send(new GetRolePolicyCommand({ RoleName: name, PolicyName: n }))).PolicyDocument, errors);
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Summary', [
          ['Role name', r.RoleName],
          ['Role ID', r.RoleId],
          ['Description', r.Description],
          ['Path', r.Path],
          ['Created', r.CreateDate],
          ['Max session duration', r.MaxSessionDuration !== undefined ? `${r.MaxSessionDuration / 3600} h` : undefined],
          ['Last used', r.RoleLastUsed?.LastUsedDate ?? 'Not used in the tracking period'],
          ['Last used region', r.RoleLastUsed?.Region],
          ['Permissions boundary', r.PermissionsBoundary?.PermissionsBoundaryArn],
          ['Instance profiles', (parts.profiles || []).map((p) => p.InstanceProfileName)],
        ]),
      ],
    }),
    tab('Permissions', { tables: [policyTable(parts.attached, parts.inline)] }),
    tab('Trust relationships', { json: policyJson(r.AssumeRolePolicyDocument), emptyMessage: 'No trust policy' }),
  ];
  if (inline) tabs.push(tab('Inline policies', { json: inline }));
  return { id, title: name, subtitle: r.Description || 'IAM role', arn: r.Arn, tabs, tags: tagList(parts.tags), actions: [], errors };
}

async function groupPage(c: IAMClient, id: string, name: string): Promise<ResourcePage> {
  const errors: string[] = [];
  const res = await c.send(new GetGroupCommand({ GroupName: name }));
  const g = res.Group;
  if (!g) throw httpError(`Group not found: ${name}`, 404);
  const parts = await settle(
    {
      users: pageAll((Marker) => c.send(new GetGroupCommand({ GroupName: name, Marker })), (x) => x.Users, marker),
      attached: pageAll((Marker) => c.send(new ListAttachedGroupPoliciesCommand({ GroupName: name, Marker })), (x) => x.AttachedPolicies, marker),
      inline: pageAll((Marker) => c.send(new ListGroupPoliciesCommand({ GroupName: name, Marker })), (x) => x.PolicyNames, marker),
    },
    errors,
  );
  const inline = await inlineDocs(parts.inline, async (n) => (await c.send(new GetGroupPolicyCommand({ GroupName: name, PolicyName: n }))).PolicyDocument, errors);
  const tabs: PageTab[] = [
    tab('Details', { sections: [section('Summary', [['Group name', g.GroupName], ['Group ID', g.GroupId], ['Path', g.Path], ['Created', g.CreateDate]])] }),
    tab('Users', { tables: [table(['User', 'ARN', 'Created'], (parts.users || []).map((u) => [u.UserName, u.Arn, u.CreateDate]), { emptyMessage: 'No users in this group' })] }),
    tab('Permissions', { tables: [policyTable(parts.attached, parts.inline)] }),
  ];
  if (inline) tabs.push(tab('Inline policies', { json: inline }));
  // IAM groups can't be tagged, so no `tags` (and no Tags tab).
  return { id, title: name, subtitle: 'IAM user group', arn: g.Arn, tabs, actions: [], errors };
}

async function policyPage(c: IAMClient, id: string, arn: string): Promise<ResourcePage> {
  const p = (await c.send(new GetPolicyCommand({ PolicyArn: arn }))).Policy;
  if (!p) throw httpError(`Policy not found: ${arn}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      doc: c.send(new GetPolicyVersionCommand({ PolicyArn: arn, VersionId: p.DefaultVersionId })),
      versions: pageAll((Marker) => c.send(new ListPolicyVersionsCommand({ PolicyArn: arn, Marker })), (x) => x.Versions, marker),
      entities: c.send(new ListEntitiesForPolicyCommand({ PolicyArn: arn })),
      tags: pageAll((Marker) => c.send(new ListPolicyTagsCommand({ PolicyArn: arn, Marker })), (x) => x.Tags, marker),
    },
    errors,
  );
  const e = parts.entities;
  return {
    id,
    title: p.PolicyName || arn,
    subtitle: p.Description || 'Customer managed policy',
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Summary', [
            ['Policy name', p.PolicyName],
            ['Policy ID', p.PolicyId],
            ['Description', p.Description],
            ['Path', p.Path],
            ['Default version', p.DefaultVersionId],
            ['Attachments', p.AttachmentCount],
            ['Used as permissions boundary', p.PermissionsBoundaryUsageCount],
            ['Created', p.CreateDate],
            ['Updated', p.UpdateDate],
          ]),
        ],
      }),
      tab('Policy document', { json: policyJson(parts.doc?.PolicyVersion?.Document), emptyMessage: 'Document not available' }),
      tab('Entities attached', {
        tables: [
          table(
            ['Entity', 'Type'],
            [...(e?.PolicyUsers || []).map((x) => [x.UserName, 'User']), ...(e?.PolicyRoles || []).map((x) => [x.RoleName, 'Role']), ...(e?.PolicyGroups || []).map((x) => [x.GroupName, 'Group'])],
            { emptyMessage: 'Not attached to any user, role or group' },
          ),
        ],
      }),
      tab('Versions', {
        tables: [table(['Version', 'Default', 'Created'], (parts.versions || []).map((v) => [v.VersionId, v.IsDefaultVersion ? 'Default' : '-', v.CreateDate]))],
      }),
    ],
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function detail(profile: string, _region: string, id: string): Promise<ResourcePage> {
  const c = client(profile);
  const [kind, rest] = splitId(id);
  if (kind === 'user') return userPage(c, id, rest);
  if (kind === 'role') return rolePage(c, id, rest);
  if (kind === 'group') return groupPage(c, id, rest);
  if (kind === 'policy') return policyPage(c, id, rest);
  throw httpError(`Unknown IAM resource: ${id}`, 400);
}

export const iamAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, _region, id, _arn, key, value) {
    const c = client(profile);
    const [kind, rest] = splitId(id);
    const Tags = [{ Key: key, Value: value }];
    if (kind === 'user') await c.send(new TagUserCommand({ UserName: rest, Tags }));
    else if (kind === 'role') await c.send(new TagRoleCommand({ RoleName: rest, Tags }));
    else if (kind === 'policy') await c.send(new TagPolicyCommand({ PolicyArn: rest, Tags }));
    else throw httpError('IAM groups cannot be tagged', 400);
  },
  async removeTag(profile, _region, id, _arn, key) {
    const c = client(profile);
    const [kind, rest] = splitId(id);
    const TagKeys = [key];
    if (kind === 'user') await c.send(new UntagUserCommand({ UserName: rest, TagKeys }));
    else if (kind === 'role') await c.send(new UntagRoleCommand({ RoleName: rest, TagKeys }));
    else if (kind === 'policy') await c.send(new UntagPolicyCommand({ PolicyArn: rest, TagKeys }));
    else throw httpError('IAM groups cannot be tagged', 400);
  },
  // Dashboard: users and roles, like the console's IAM dashboard.
  countable: (row) => row.id.startsWith('user:') || row.id.startsWith('role:'),
};
