import {
  ConnectClient,
  ListInstancesCommand,
  DescribeInstanceCommand,
  ListQueuesCommand,
  ListContactFlowsCommand,
  ListUsersCommand,
  ListPhoneNumbersV2Command,
  ListHoursOfOperationsCommand,
  ListRoutingProfilesCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-connect';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Amazon Connect: instances with their queues, flows, users, phone numbers, hours and routing profiles. */
const client = (p: string, r: string) => new ConnectClient(clientConfig(p, r));
const USER_LIMIT = 500;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const instances = await pageAll((NextToken) => client(profile, region).send(new ListInstancesCommand({ NextToken })), (r) => r.InstanceSummaryList, (r) => r.NextToken);
  return instances.map((i) => ({ id: `inst:${i.Id}`, name: i.InstanceAlias || i.Id || '', status: i.InstanceStatus, info: [i.IdentityManagementType, i.InboundCallsEnabled && 'inbound', i.OutboundCallsEnabled && 'outbound'].filter(Boolean).join(' · ') })).sort(byName);
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, instanceId] = splitId(id);
  if (kind !== 'inst') throw httpError(`Unknown Connect page: ${id}`, 400);
  const c = client(profile, region);
  const i = (await c.send(new DescribeInstanceCommand({ InstanceId: instanceId }))).Instance;
  if (!i) throw httpError(`Instance not found: ${instanceId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      queues: pageAll((NextToken) => c.send(new ListQueuesCommand({ InstanceId: instanceId, NextToken, QueueTypes: ['STANDARD'] })), (r) => r.QueueSummaryList, (r) => r.NextToken),
      flows: pageAll((NextToken) => c.send(new ListContactFlowsCommand({ InstanceId: instanceId, NextToken })), (r) => r.ContactFlowSummaryList, (r) => r.NextToken),
      users: pageAll((NextToken) => c.send(new ListUsersCommand({ InstanceId: instanceId, NextToken })), (r) => r.UserSummaryList, (r) => r.NextToken, USER_LIMIT),
      numbers: pageAll((NextToken) => c.send(new ListPhoneNumbersV2Command({ TargetArn: i.Arn, NextToken })), (r) => r.ListPhoneNumbersSummaryList, (r) => r.NextToken),
      hours: pageAll((NextToken) => c.send(new ListHoursOfOperationsCommand({ InstanceId: instanceId, NextToken })), (r) => r.HoursOfOperationSummaryList, (r) => r.NextToken),
      routing: pageAll((NextToken) => c.send(new ListRoutingProfilesCommand({ InstanceId: instanceId, NextToken })), (r) => r.RoutingProfileSummaryList, (r) => r.NextToken),
    },
    errors,
  );
  return {
    id,
    title: i.InstanceAlias || instanceId,
    subtitle: 'Amazon Connect instance',
    status: i.InstanceStatus,
    arn: i.Arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Instance', [['Instance ID', i.Id], ['Status', i.InstanceStatus], ['Status reason', i.StatusReason?.Message], ['Identity management', i.IdentityManagementType], ['Inbound calls', i.InboundCallsEnabled], ['Outbound calls', i.OutboundCallsEnabled], ['Service role', i.ServiceRole], ['Created', i.CreatedTime]]),
          ...(i.InstanceAccessUrl ? [{ title: 'Access', settings: [], copyable: [{ label: 'Access URL', value: i.InstanceAccessUrl }] }] : []),
        ],
        tables: [table(['Phone number', 'Type', 'Country', 'Description'], (parts.numbers || []).map((n) => [n.PhoneNumber, n.PhoneNumberType, n.PhoneNumberCountryCode, n.PhoneNumberDescription]), { title: 'Phone numbers', emptyMessage: 'No claimed numbers' })],
      }),
      tab('Flows', {
        tables: [table(['Flow', 'Type', 'State', 'Status'], (parts.flows || []).sort((a, b) => (a.Name || '').localeCompare(b.Name || '')).map((f) => [f.Name, f.ContactFlowType, f.ContactFlowState, f.ContactFlowStatus]), { statusColumn: 2, emptyMessage: 'No flows' })],
      }),
      tab('Queues & routing', {
        tables: [
          table(['Queue', 'Modified'], (parts.queues || []).map((q) => [q.Name, q.LastModifiedTime]), { title: 'Queues', emptyMessage: 'No queues' }),
          table(['Routing profile', 'Modified'], (parts.routing || []).map((r) => [r.Name, r.LastModifiedTime]), { title: 'Routing profiles', emptyMessage: 'No routing profiles' }),
          table(['Hours of operation', 'Modified'], (parts.hours || []).map((h) => [h.Name, h.LastModifiedTime]), { title: 'Hours of operation', emptyMessage: 'None' }),
        ],
      }),
      tab('Users', {
        tables: [table(['User', 'Modified'], (parts.users || []).map((u) => [u.Username, u.LastModifiedTime]), { title: (parts.users?.length ?? 0) >= USER_LIMIT ? `First ${USER_LIMIT} users` : `${parts.users?.length ?? 0} users`, emptyMessage: 'No users' })],
      }),
    ],
    tags: tagMap(i.Tags),
    actions: [],
    errors,
  };
}

export const connectAdapter: PageServiceAdapter = {
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
