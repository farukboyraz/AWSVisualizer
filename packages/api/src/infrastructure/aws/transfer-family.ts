import {
  TransferClient,
  ListServersCommand,
  DescribeServerCommand,
  ListUsersCommand,
  ListConnectorsCommand,
  DescribeConnectorCommand,
  ListWorkflowsCommand,
  DescribeWorkflowCommand,
  TagResourceCommand as TfTag,
  UntagResourceCommand as TfUntag,
} from '@aws-sdk/client-transfer';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Transfer Family. */
const tf = (p: string, r: string) => new TransferClient(clientConfig(p, r));

export const transferAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = tf(profile, region);
    const [servers, connectors, workflows] = await Promise.all([
      pageAll((NextToken) => c.send(new ListServersCommand({ NextToken })), (r) => r.Servers, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListConnectorsCommand({ NextToken })), (r) => r.Connectors, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListWorkflowsCommand({ NextToken })), (r) => r.Workflows, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      ...servers.map((s) => ({ id: `srv:${s.ServerId}`, name: s.ServerId || '', group: 'Servers', status: s.State, info: [s.Domain, s.EndpointType, s.IdentityProviderType, `${s.UserCount ?? 0} users`].filter(Boolean).join(' · ') })).sort(byName),
      ...connectors.map((x) => ({ id: `con:${x.ConnectorId}`, name: x.ConnectorId || '', group: 'Connectors', info: x.Url })).sort(byName),
      ...workflows.map((w) => ({ id: `wf:${w.WorkflowId}`, name: w.WorkflowId || '', group: 'Workflows', info: w.Description })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = tf(profile, region);
    const [kind, rest] = splitId(id);
    const errors: string[] = [];
    if (kind === 'srv') {
      const s = (await c.send(new DescribeServerCommand({ ServerId: rest }))).Server;
      if (!s) throw httpError(`Server not found: ${rest}`, 404);
      const { users } = await settle({ users: pageAll((NextToken) => c.send(new ListUsersCommand({ ServerId: rest, NextToken })), (r) => r.Users, (r) => r.NextToken) }, errors);
      const ep = s.EndpointDetails;
      return {
        id,
        title: rest,
        subtitle: `${(s.Protocols || []).join(' / ')} server`,
        status: s.State,
        arn: s.Arn,
        tabs: [
          tab('Details', {
            sections: [
              section('Server', [
                ['State', s.State],
                ['Protocols', s.Protocols],
                ['Storage', s.Domain],
                ['Endpoint type', s.EndpointType],
                ['VPC', ep?.VpcId],
                ['Elastic IPs', ep?.AddressAllocationIds],
                ['Identity provider', s.IdentityProviderType],
                ['Provider endpoint', s.IdentityProviderDetails?.Url ?? s.IdentityProviderDetails?.Function ?? s.IdentityProviderDetails?.DirectoryId],
                ['Security policy', s.SecurityPolicyName],
                ['Host key fingerprint', s.HostKeyFingerprint],
                ['Certificate', s.Certificate],
                ['Logging role', s.LoggingRole],
                ['Workflows on upload', (s.WorkflowDetails?.OnUpload || []).map((w) => w.WorkflowId)],
              ]),
              { title: 'Endpoint', settings: [], copyable: [{ label: 'Host', value: `${rest}.server.transfer.${region}.amazonaws.com` }] },
            ],
          }),
          tab('Users', {
            tables: [table(['User', 'Home directory', 'Type', 'Role', 'SSH keys'], (users || []).map((u) => [u.UserName, u.HomeDirectory, u.HomeDirectoryType, lastPart(u.Role), u.SshPublicKeyCount]), { emptyMessage: s.IdentityProviderType === 'SERVICE_MANAGED' ? 'No users' : 'Users come from the identity provider' })],
          }),
        ],
        tags: tagList(s.Tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'con') {
      const x = (await c.send(new DescribeConnectorCommand({ ConnectorId: rest }))).Connector;
      if (!x) throw httpError(`Connector not found: ${rest}`, 404);
      return {
        id,
        title: rest,
        subtitle: x.As2Config ? 'AS2 connector' : 'SFTP connector',
        arn: x.Arn,
        tabs: [tab('Details', { sections: [section('Connector', [['URL', x.Url], ['Access role', x.AccessRole], ['Logging role', x.LoggingRole], ['Credentials secret', x.SftpConfig?.UserSecretId], ['Trusted host keys', x.SftpConfig?.TrustedHostKeys?.length], ['AS2 partner', x.As2Config?.PartnerProfileId], ['Service IPs', x.ServiceManagedEgressIpAddresses]])] })],
        tags: tagList(x.Tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'wf') {
      const w = (await c.send(new DescribeWorkflowCommand({ WorkflowId: rest }))).Workflow;
      if (!w) throw httpError(`Workflow not found: ${rest}`, 404);
      return {
        id,
        title: rest,
        subtitle: w.Description || 'Transfer workflow',
        arn: w.Arn,
        tabs: [
          tab('Steps', {
            tables: [
              table(['#', 'Step', 'Type'], (w.Steps || []).map((s, i) => [i + 1, s.CopyStepDetails?.Name ?? s.CustomStepDetails?.Name ?? s.DeleteStepDetails?.Name ?? s.TagStepDetails?.Name ?? s.DecryptStepDetails?.Name, s.Type]), { title: 'Steps', emptyMessage: 'No steps' }),
              table(['#', 'Step', 'Type'], (w.OnExceptionSteps || []).map((s, i) => [i + 1, s.CopyStepDetails?.Name ?? s.CustomStepDetails?.Name ?? s.DeleteStepDetails?.Name, s.Type]), { title: 'On exception', emptyMessage: 'None' }),
            ],
          }),
        ],
        tags: tagList(w.Tags),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown Transfer Family page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await tf(profile, region).send(new TfTag({ Arn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await tf(profile, region).send(new TfUntag({ Arn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('srv:'),
};
