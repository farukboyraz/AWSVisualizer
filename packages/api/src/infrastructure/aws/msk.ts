import {
  KafkaClient,
  ListClustersV2Command,
  DescribeClusterV2Command,
  GetBootstrapBrokersCommand,
  ListNodesCommand,
  ListClusterOperationsCommand,
  ListConfigurationsCommand,
  DescribeConfigurationCommand,
  DescribeConfigurationRevisionCommand,
  TagResourceCommand,
  UntagResourceCommand,
  ListTagsForResourceCommand,
} from '@aws-sdk/client-kafka';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new KafkaClient({ region: r, credentials: cachedCredentials(p) });

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [clusters, configs] = await Promise.all([
    pageAll((NextToken) => c.send(new ListClustersV2Command({ NextToken })), (r) => r.ClusterInfoList, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListConfigurationsCommand({ NextToken })), (r) => r.Configurations, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...clusters
      .map((x) => ({
        id: `cl:${x.ClusterArn}`,
        name: x.ClusterName || '',
        group: 'Clusters',
        status: x.State,
        info: x.ClusterType === 'SERVERLESS' ? 'Serverless' : `${x.Provisioned?.NumberOfBrokerNodes ?? 0}× ${x.Provisioned?.BrokerNodeGroupInfo?.InstanceType ?? ''} · Kafka ${x.Provisioned?.CurrentBrokerSoftwareInfo?.KafkaVersion ?? '-'}`,
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    ...configs.map((x) => ({ id: `cfg:${x.Arn}`, name: x.Name || '', group: 'Configurations', status: x.State, info: `rev ${x.LatestRevision?.Revision ?? '-'} · ${(x.KafkaVersions || []).join(', ')}` })),
  ];
}

async function clusterPage(c: KafkaClient, id: string, arn: string): Promise<ResourcePage> {
  const x = (await c.send(new DescribeClusterV2Command({ ClusterArn: arn }))).ClusterInfo;
  if (!x) throw httpError(`Cluster not found: ${arn}`, 404);
  const prov = x.Provisioned;
  const errors: string[] = [];
  const parts = await settle(
    {
      brokers: c.send(new GetBootstrapBrokersCommand({ ClusterArn: arn })),
      nodes: prov ? pageAll((NextToken) => c.send(new ListNodesCommand({ ClusterArn: arn, NextToken })), (r) => r.NodeInfoList, (r) => r.NextToken) : Promise.resolve([]),
      ops: c.send(new ListClusterOperationsCommand({ ClusterArn: arn, MaxResults: 25 })),
    },
    errors,
  );
  const b = parts.brokers;
  const bootstrap = ([
    ['Plaintext', b?.BootstrapBrokerString],
    ['TLS', b?.BootstrapBrokerStringTls],
    ['SASL/SCRAM', b?.BootstrapBrokerStringSaslScram],
    ['SASL/IAM', b?.BootstrapBrokerStringSaslIam],
    ['Public TLS', b?.BootstrapBrokerStringPublicTls],
    ['Public SASL/IAM', b?.BootstrapBrokerStringPublicSaslIam],
    ['VPC connectivity SASL/IAM', b?.BootstrapBrokerStringVpcConnectivitySaslIam],
  ] as [string, string | undefined][]).filter(([, v]) => v);
  const auth = prov?.ClientAuthentication;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Cluster', [
          ['Type', x.ClusterType],
          ['State', x.State],
          ['State info', x.StateInfo?.Message],
          ['Kafka version', prov?.CurrentBrokerSoftwareInfo?.KafkaVersion],
          ['Configuration', prov?.CurrentBrokerSoftwareInfo?.ConfigurationArn && `${prov.CurrentBrokerSoftwareInfo.ConfigurationArn.split('/')[1]} rev ${prov.CurrentBrokerSoftwareInfo.ConfigurationRevision}`],
          ['Brokers', prov ? `${prov.NumberOfBrokerNodes} × ${prov.BrokerNodeGroupInfo?.InstanceType}` : undefined],
          ['Storage per broker', prov?.BrokerNodeGroupInfo?.StorageInfo?.EbsStorageInfo?.VolumeSize && `${prov.BrokerNodeGroupInfo.StorageInfo.EbsStorageInfo.VolumeSize} GiB`],
          ['Storage mode', prov?.StorageMode],
          ['Subnets', prov?.BrokerNodeGroupInfo?.ClientSubnets ?? (x.Serverless?.VpcConfigs || []).flatMap((v) => v.SubnetIds || [])],
          ['Security groups', prov?.BrokerNodeGroupInfo?.SecurityGroups ?? (x.Serverless?.VpcConfigs || []).flatMap((v) => v.SecurityGroupIds || [])],
          ['Client auth', [auth?.Sasl?.Iam?.Enabled && 'IAM', auth?.Sasl?.Scram?.Enabled && 'SCRAM', auth?.Tls?.Enabled && 'mTLS', auth?.Unauthenticated?.Enabled && 'Unauthenticated', x.Serverless?.ClientAuthentication?.Sasl?.Iam?.Enabled && 'IAM'].filter(Boolean)],
          ['Encryption in transit', prov?.EncryptionInfo?.EncryptionInTransit?.ClientBroker],
          ['Encryption at rest', prov?.EncryptionInfo?.EncryptionAtRest?.DataVolumeKMSKeyId],
          ['Monitoring', prov?.EnhancedMonitoring],
          ['Created', x.CreationTime],
        ]),
        { title: 'Bootstrap brokers', settings: [], copyable: bootstrap.map(([label, value]) => ({ label, value: value! })) },
      ].filter((s) => s.settings.length || ('copyable' in s && s.copyable?.length)),
    }),
  ];
  if (prov) {
    tabs.push(
      tab('Brokers', {
        tables: [table(['Broker', 'Instance type', 'Subnet', 'Client IP', 'Endpoints', 'Added'], (parts.nodes || []).filter((n) => n.BrokerNodeInfo).map((n) => [n.BrokerNodeInfo?.BrokerId, n.InstanceType, n.BrokerNodeInfo?.ClientSubnet, n.BrokerNodeInfo?.ClientVpcIpAddress, n.BrokerNodeInfo?.Endpoints, n.AddedToClusterTime]), { emptyMessage: 'No brokers' })],
      }),
    );
  }
  tabs.push(
    tab('Operations', {
      tables: [table(['Operation', 'State', 'Started', 'Ended', 'Error'], (parts.ops?.ClusterOperationInfoList || []).map((o) => [o.OperationType, o.OperationState, o.CreationTime, o.EndTime, o.ErrorInfo?.ErrorString]), { statusColumn: 1, title: 'Last 25 operations', emptyMessage: 'No operations' })],
    }),
  );
  return { id, title: x.ClusterName || arn, subtitle: `MSK ${x.ClusterType === 'SERVERLESS' ? 'Serverless' : 'provisioned'} cluster`, status: x.State, arn, tabs, tags: tagMap(x.Tags), actions: [], errors };
}

async function configPage(c: KafkaClient, id: string, arn: string): Promise<ResourcePage> {
  const cfg = await c.send(new DescribeConfigurationCommand({ Arn: arn }));
  const errors: string[] = [];
  const parts = await settle(
    {
      revision: cfg.LatestRevision?.Revision !== undefined ? c.send(new DescribeConfigurationRevisionCommand({ Arn: arn, Revision: cfg.LatestRevision.Revision })) : Promise.resolve(undefined),
      tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })),
    },
    errors,
  );
  const props = parts.revision?.ServerProperties ? Buffer.from(parts.revision.ServerProperties).toString('utf-8') : undefined;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [section('Configuration', [['Name', cfg.Name], ['State', cfg.State], ['Description', cfg.Description], ['Kafka versions', cfg.KafkaVersions], ['Latest revision', cfg.LatestRevision?.Revision], ['Revision note', cfg.LatestRevision?.Description], ['Created', cfg.CreationTime]])],
    }),
  ];
  if (props) tabs.push(tab('server.properties', { text: props }));
  return { id, title: cfg.Name || arn, subtitle: 'MSK configuration', status: cfg.State, arn, tabs, tags: tagMap(parts.tags?.Tags), actions: [], errors };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, arn] = splitId(id);
  if (kind === 'cl') return clusterPage(c, id, arn);
  if (kind === 'cfg') return configPage(c, id, arn);
  throw httpError(`Unknown MSK page: ${id}`, 400);
}

export const mskAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: splitId(id)[1], Tags: { [key]: value } }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: splitId(id)[1], TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('cl:'),
};
