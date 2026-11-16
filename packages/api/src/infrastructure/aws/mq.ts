import {
  MqClient,
  ListBrokersCommand,
  DescribeBrokerCommand,
  ListUsersCommand,
  ListConfigurationsCommand,
  DescribeConfigurationCommand,
  ListConfigurationRevisionsCommand,
  DescribeConfigurationRevisionCommand,
  CreateTagsCommand,
  DeleteTagsCommand,
} from '@aws-sdk/client-mq';
import type { PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Amazon MQ. */
const mq = (p: string, r: string) => new MqClient(clientConfig(p, r));

export const mqAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = mq(profile, region);
    const [brokers, configs] = await Promise.all([
      pageAll((NextToken) => c.send(new ListBrokersCommand({ NextToken })), (r) => r.BrokerSummaries, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListConfigurationsCommand({ NextToken })), (r) => r.Configurations, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      ...brokers.map((b) => ({ id: `br:${b.BrokerId}`, name: b.BrokerName || '', group: 'Brokers', status: b.BrokerState, info: `${b.EngineType} · ${b.DeploymentMode} · ${b.HostInstanceType ?? ''}` })).sort(byName),
      ...configs.map((x) => ({ id: `cfg:${x.Id}`, name: x.Name || '', group: 'Configurations', info: `${x.EngineType} ${x.EngineVersion} · rev ${x.LatestRevision?.Revision ?? '-'}` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = mq(profile, region);
    const [kind, rest] = splitId(id);
    const errors: string[] = [];
    if (kind === 'br') {
      const b = await c.send(new DescribeBrokerCommand({ BrokerId: rest }));
      // Usernames only - Amazon MQ never returns passwords.
      const { users } = await settle({ users: b.EngineType === 'RABBITMQ' ? Promise.resolve(undefined) : c.send(new ListUsersCommand({ BrokerId: rest })) }, errors);
      const endpoints = (b.BrokerInstances || []).flatMap((i) => [...(i.Endpoints || []), i.ConsoleURL].filter(Boolean)) as string[];
      return {
        id,
        title: b.BrokerName || rest,
        subtitle: `${b.EngineType} ${b.EngineVersion ?? ''} broker`,
        status: b.BrokerState,
        arn: b.BrokerArn,
        tabs: [
          tab('Details', {
            sections: [
              section('Broker', [
                ['State', b.BrokerState],
                ['Engine', `${b.EngineType} ${b.EngineVersion}`],
                ['Deployment', b.DeploymentMode],
                ['Instance type', b.HostInstanceType],
                ['Storage', b.StorageType],
                ['Publicly accessible', b.PubliclyAccessible],
                ['Authentication', b.AuthenticationStrategy],
                ['Configuration', b.Configurations?.Current && `${b.Configurations.Current.Id} rev ${b.Configurations.Current.Revision}`],
                ['Auto minor upgrade', b.AutoMinorVersionUpgrade],
                ['Maintenance window', b.MaintenanceWindowStartTime && `${b.MaintenanceWindowStartTime.DayOfWeek} ${b.MaintenanceWindowStartTime.TimeOfDay} ${b.MaintenanceWindowStartTime.TimeZone ?? ''}`],
                ['Subnets', b.SubnetIds],
                ['Security groups', b.SecurityGroups],
                ['Logs', [b.Logs?.General && 'general', b.Logs?.Audit && 'audit'].filter(Boolean)],
                ['Actions required', (b.ActionsRequired || []).map((a) => a.ActionRequiredInfo)],
                ['Created', b.Created],
              ]),
              { title: 'Endpoints', settings: [], copyable: endpoints.map((e) => ({ label: e.startsWith('https') ? 'Console' : e.split(':')[0], value: e })) },
            ].filter((s) => s.settings.length || ('copyable' in s && s.copyable?.length)),
          }),
          tab('Users', {
            tables: [table(['User', 'Pending change'], (users?.Users || []).map((u) => [u.Username, u.PendingChange]), { emptyMessage: b.EngineType === 'RABBITMQ' ? 'RabbitMQ users are managed in the RabbitMQ console' : 'No users' })],
          }),
        ],
        tags: tagMap(b.Tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'cfg') {
      const x = await c.send(new DescribeConfigurationCommand({ ConfigurationId: rest }));
      const parts = await settle(
        {
          revisions: c.send(new ListConfigurationRevisionsCommand({ ConfigurationId: rest })),
          latest: x.LatestRevision?.Revision !== undefined ? c.send(new DescribeConfigurationRevisionCommand({ ConfigurationId: rest, ConfigurationRevision: String(x.LatestRevision.Revision) })) : Promise.resolve(undefined),
        },
        errors,
      );
      const data = parts.latest?.Data ? Buffer.from(parts.latest.Data, 'base64').toString('utf-8') : undefined;
      const tabs: PageTab[] = [
        tab('Details', {
          sections: [section('Configuration', [['Engine', `${x.EngineType} ${x.EngineVersion}`], ['Authentication', x.AuthenticationStrategy], ['Latest revision', x.LatestRevision?.Revision], ['Description', x.Description], ['Created', x.Created]])],
          tables: [table(['Revision', 'Created', 'Description'], (parts.revisions?.Revisions || []).map((r) => [r.Revision, r.Created, r.Description]), { title: 'Revisions', emptyMessage: 'No revisions' })],
        }),
      ];
      if (data) tabs.push(tab('Latest revision', { text: data }));
      return { id, title: x.Name || rest, subtitle: 'Broker configuration', arn: x.Arn, tabs, tags: tagMap(x.Tags), actions: [], errors };
    }
    throw httpError(`Unknown MQ page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await mq(profile, region).send(new CreateTagsCommand({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await mq(profile, region).send(new DeleteTagsCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('br:'),
};
