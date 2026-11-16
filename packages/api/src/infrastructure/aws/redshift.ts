import {
  RedshiftClient,
  DescribeClustersCommand,
  DescribeClusterSnapshotsCommand,
  DescribeEventsCommand,
  CreateTagsCommand,
  DeleteTagsCommand,
  PauseClusterCommand,
  ResumeClusterCommand,
  RebootClusterCommand,
  CreateClusterSnapshotCommand,
  type Cluster,
} from '@aws-sdk/client-redshift';
import {
  RedshiftServerlessClient,
  ListWorkgroupsCommand,
  GetWorkgroupCommand,
  GetNamespaceCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-redshift-serverless';
import { cachedCredentials } from './credential-cache.js';
import type { PageAction, ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError, metricChart, snapshotNameField, nameStamp, EVENT_WINDOW_MINUTES } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const provisioned = (p: string, r: string) => new RedshiftClient({ region: r, credentials: cachedCredentials(p) });
const serverless = (p: string, r: string) => new RedshiftServerlessClient({ region: r, credentials: cachedCredentials(p) });

async function clusters(c: RedshiftClient, id?: string): Promise<Cluster[]> {
  const out: Cluster[] = [];
  let Marker: string | undefined;
  do {
    const res = await c.send(new DescribeClustersCommand({ ClusterIdentifier: id, Marker }));
    out.push(...(res.Clusters || []));
    Marker = res.Marker;
  } while (Marker);
  return out;
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const sc = serverless(profile, region);
  const [cls, wgs] = await Promise.all([
    clusters(provisioned(profile, region)),
    (async () => {
      const out: { workgroupName?: string; namespaceName?: string; status?: string; baseCapacity?: number }[] = [];
      let nextToken: string | undefined;
      do {
        const res = await sc.send(new ListWorkgroupsCommand({ nextToken }));
        out.push(...(res.workgroups || []));
        nextToken = res.nextToken;
      } while (nextToken);
      return out;
    })().catch(() => []),
  ]);
  return [
    ...cls.map((cl) => ({
      id: `cl:${cl.ClusterIdentifier}`,
      name: cl.ClusterIdentifier || '',
      group: 'Provisioned clusters',
      status: cl.ClusterStatus,
      info: [cl.NodeType, `${cl.NumberOfNodes ?? 0} nodes`, cl.DBName].filter(Boolean).join(' · '),
    })),
    ...wgs.map((w) => ({
      id: `wg:${w.workgroupName}`,
      name: w.workgroupName || '',
      group: 'Serverless workgroups',
      status: w.status,
      info: [w.namespaceName && `namespace ${w.namespaceName}`, w.baseCapacity && `${w.baseCapacity} RPU base`].filter(Boolean).join(' · '),
    })),
  ].sort((a, b) => a.group.localeCompare(b.group) || a.name.localeCompare(b.name));
}

function clusterActions(cl: Cluster): PageAction[] {
  const s = cl.ClusterStatus;
  const out: PageAction[] = [];
  if (s === 'available') {
    out.push({
      id: 'snapshot',
      title: 'Take snapshot',
      systemImage: 'camera',
      confirmTitle: `Take a snapshot of ${cl.ClusterIdentifier}?`,
      confirmMessage: 'A manual snapshot is created and kept for the retention you chose; its storage is billed.',
      destructive: false,
      form: [
        snapshotNameField(`${cl.ClusterIdentifier}-manual-${nameStamp()}`),
        {
          key: 'retention',
          label: { en: 'Retention', tr: 'Saklama süresi' },
          type: 'select',
          required: true,
          defaultValue: '-1',
          choices: [
            { value: '-1', label: { en: 'Until deleted', tr: 'Silinene kadar' } },
            { value: '1', label: { en: '1 day', tr: '1 gün' } },
            { value: '7', label: { en: '7 days', tr: '7 gün' } },
            { value: '30', label: { en: '30 days', tr: '30 gün' } },
            { value: '90', label: { en: '90 days', tr: '90 gün' } },
            { value: '365', label: { en: '1 year', tr: '1 yıl' } },
          ],
        },
      ],
    });
    out.push({ id: 'pause', title: 'Pause', systemImage: 'pause.fill', confirmTitle: `Pause ${cl.ClusterIdentifier}?`, confirmMessage: 'Compute billing stops; storage is still billed. Queries fail until the cluster is resumed.', destructive: true });
    out.push({ id: 'reboot', title: 'Reboot', systemImage: 'arrow.clockwise', confirmTitle: `Reboot ${cl.ClusterIdentifier}?`, confirmMessage: 'The cluster is unavailable for a few minutes and running queries are cancelled.', destructive: true });
  }
  if (s === 'paused') {
    out.push({ id: 'resume', title: 'Resume', systemImage: 'play.fill', confirmTitle: `Resume ${cl.ClusterIdentifier}?`, confirmMessage: 'Compute billing starts again once the cluster is available.', destructive: false });
  }
  return out;
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, name] = splitId(id);
  const errors: string[] = [];

  if (kind === 'cl') {
    const c = provisioned(profile, region);
    const cl = (await clusters(c, name))[0];
    if (!cl) throw httpError(`Cluster not found: ${name}`, 404);
    const { snaps, events } = await settle(
      {
        snaps: c.send(new DescribeClusterSnapshotsCommand({ ClusterIdentifier: name, MaxRecords: 100 })),
        events: c.send(new DescribeEventsCommand({ SourceIdentifier: name, SourceType: 'cluster', Duration: EVENT_WINDOW_MINUTES })),
      },
      errors,
    );
    // DescribeClusters has no cluster ARN; build it from the namespace ARN's partition and account.
    const [, partition, , , account] = cl.ClusterNamespaceArn?.split(':') || [];
    const arn = account ? `arn:${partition}:redshift:${region}:${account}:cluster:${name}` : undefined;
    const ep = cl.Endpoint?.Address;
    const port = cl.Endpoint?.Port;
    return {
      id,
      title: name,
      subtitle: `${cl.NodeType} · ${cl.NumberOfNodes} nodes`,
      status: cl.ClusterStatus,
      arn,
      tabs: [
        tab('General information', {
          sections: [
            section('General', [
              ['Status', cl.ClusterStatus],
              ['Availability', cl.ClusterAvailabilityStatus],
              ['Node type', cl.NodeType],
              ['Number of nodes', cl.NumberOfNodes],
              ['Storage capacity', cl.TotalStorageCapacityInMegaBytes !== undefined ? `${(cl.TotalStorageCapacityInMegaBytes / 1024 / 1024).toFixed(1)} TB` : undefined],
              ['Multi-AZ', cl.MultiAZ],
              ['Cluster version', cl.ClusterVersion],
              ['Maintenance track', cl.MaintenanceTrackName],
              ['Database name', cl.DBName],
              ['Admin user', cl.MasterUsername],
              ['Admin password', cl.MasterPasswordSecretArn ? 'Managed in Secrets Manager' : undefined],
              ['Created', cl.ClusterCreateTime],
              ['Pending actions', cl.PendingActions],
            ]),
            {
              title: 'Connection',
              settings: [],
              copyable: [
                { label: 'Endpoint', value: ep ? `${ep}:${port}/${cl.DBName}` : '-' },
                { label: 'JDBC URL', value: ep ? `jdbc:redshift://${ep}:${port}/${cl.DBName}` : '-' },
                { label: 'psql', value: ep ? `psql -h ${ep} -p ${port} -U ${cl.MasterUsername} -d ${cl.DBName}` : '-' },
              ].filter((e) => e.value !== '-'),
            },
          ],
        }),
        tab('Monitoring', {
          charts: [
            metricChart('CPU utilization', 'AWS/Redshift', { ClusterIdentifier: name }, [['CPUUtilization', 'Average']], '%'),
            metricChart('Database connections', 'AWS/Redshift', { ClusterIdentifier: name }, [['DatabaseConnections', 'Maximum']]),
            metricChart('Disk space used', 'AWS/Redshift', { ClusterIdentifier: name }, [['PercentageDiskSpaceUsed', 'Maximum']], '%'),
            metricChart('Health', 'AWS/Redshift', { ClusterIdentifier: name }, [['HealthStatus', 'Minimum', '1 = healthy']]),
          ],
        }),
        tab('Nodes', {
          tables: [table(['Role', 'Private IP', 'Public IP'], (cl.ClusterNodes || []).map((n) => [n.NodeRole, n.PrivateIPAddress, n.PublicIPAddress]))],
        }),
        tab('Properties', {
          sections: [
            section('Network and security', [
              ['VPC', cl.VpcId],
              ['Subnet group', cl.ClusterSubnetGroupName],
              ['Availability Zone', cl.AvailabilityZone],
              ['Security groups', (cl.VpcSecurityGroups || []).map((g) => `${g.VpcSecurityGroupId} (${g.Status})`)],
              ['Publicly accessible', cl.PubliclyAccessible],
              ['Enhanced VPC routing', cl.EnhancedVpcRouting],
              ['IP address type', cl.IpAddressType],
              ['Encrypted', cl.Encrypted],
              ['KMS key', cl.KmsKeyId],
            ]),
            section('Database configuration', [
              ['Parameter groups', (cl.ClusterParameterGroups || []).map((p) => `${p.ParameterGroupName} (${p.ParameterApplyStatus})`)],
              ['IAM roles', (cl.IamRoles || []).map((r) => r.IamRoleArn?.split('/').pop())],
              ['Default IAM role', cl.DefaultIamRoleArn?.split('/').pop()],
            ]),
          ],
        }),
        tab('Maintenance', {
          sections: [
            section('Maintenance and backups', [
              ['Maintenance window', cl.PreferredMaintenanceWindow],
              ['Next maintenance', cl.NextMaintenanceWindowStartTime],
              ['Allow version upgrade', cl.AllowVersionUpgrade],
              ['Automated snapshot retention', cl.AutomatedSnapshotRetentionPeriod !== undefined ? `${cl.AutomatedSnapshotRetentionPeriod} days` : undefined],
              ['Manual snapshot retention', cl.ManualSnapshotRetentionPeriod === -1 ? 'Indefinitely' : cl.ManualSnapshotRetentionPeriod],
              ['Snapshot schedule', cl.SnapshotScheduleIdentifier],
              ['Next scheduled snapshot', cl.ExpectedNextSnapshotScheduleTime],
              ['Cross-region snapshot copy', cl.ClusterSnapshotCopyStatus?.DestinationRegion],
            ]),
          ],
          tables: [
            table(
              ['Snapshot', 'Type', 'Status', 'Created', 'Size'],
              (snaps?.Snapshots || [])
                .sort((a, b) => (b.SnapshotCreateTime?.getTime() || 0) - (a.SnapshotCreateTime?.getTime() || 0))
                .map((s) => [s.SnapshotIdentifier, s.SnapshotType, s.Status, s.SnapshotCreateTime, s.TotalBackupSizeInMegaBytes !== undefined ? `${s.TotalBackupSizeInMegaBytes.toFixed(0)} MB` : undefined]),
              { title: 'Snapshots (latest 100)', statusColumn: 2, emptyMessage: 'No snapshots' },
            ),
          ],
        }),
        tab('Events', {
          tables: [table(['Date', 'Severity', 'Message'], (events?.Events || []).map((e) => [e.Date, e.Severity, e.Message]), { emptyMessage: 'No events in the last 7 days' })],
        }),
      ],
      tags: tagList(cl.Tags),
      actions: clusterActions(cl),
      errors,
    };
  }

  if (kind === 'wg') {
    const sc = serverless(profile, region);
    const wg = (await sc.send(new GetWorkgroupCommand({ workgroupName: name }))).workgroup;
    if (!wg) throw httpError(`Workgroup not found: ${name}`, 404);
    const { ns, tags } = await settle(
      {
        ns: wg.namespaceName ? sc.send(new GetNamespaceCommand({ namespaceName: wg.namespaceName })) : Promise.resolve(undefined),
        tags: wg.workgroupArn ? sc.send(new ListTagsForResourceCommand({ resourceArn: wg.workgroupArn })) : Promise.resolve(undefined),
      },
      errors,
    );
    const n = ns?.namespace;
    const ep = wg.endpoint;
    return {
      id,
      title: name,
      subtitle: `Serverless · namespace ${wg.namespaceName}`,
      status: wg.status,
      arn: wg.workgroupArn,
      tabs: [
        tab('Workgroup', {
          sections: [
            section('General', [
              ['Status', wg.status],
              ['Base capacity', wg.baseCapacity && `${wg.baseCapacity} RPU`],
              ['Max capacity', wg.maxCapacity && `${wg.maxCapacity} RPU`],
              ['Version', wg.workgroupVersion],
              ['Patch version', wg.patchVersion],
              ['Created', wg.creationDate],
              ['Custom domain', wg.customDomainName],
            ]),
            { title: 'Connection', settings: [], copyable: ep?.address ? [{ label: 'Endpoint', value: `${ep.address}:${ep.port}` }, { label: 'JDBC URL', value: `jdbc:redshift://${ep.address}:${ep.port}/${n?.dbName ?? 'dev'}` }] : [] },
            section('Network and security', [
              ['Subnets', wg.subnetIds],
              ['Security groups', wg.securityGroupIds],
              ['Publicly accessible', wg.publiclyAccessible],
              ['Enhanced VPC routing', wg.enhancedVpcRouting],
              ['VPC endpoints', (ep?.vpcEndpoints || []).map((v) => v.vpcEndpointId)],
            ]),
          ],
          tables: [table(['Parameter', 'Value'], (wg.configParameters || []).map((p) => [p.parameterKey, p.parameterValue]), { title: 'Configuration parameters' })],
        }),
        tab('Namespace', {
          sections: [
            section(`Namespace ${wg.namespaceName ?? ''}`, [
              ['Status', n?.status],
              ['Database', n?.dbName],
              ['Admin user', n?.adminUsername],
              ['Admin password', n?.adminPasswordSecretArn ? 'Managed in Secrets Manager' : undefined],
              ['KMS key', n?.kmsKeyId],
              ['Default IAM role', n?.defaultIamRoleArn?.split('/').pop()],
              ['IAM roles', (n?.iamRoles || []).map((r) => r.split('/').pop())],
              ['Log exports', n?.logExports],
              ['Created', n?.creationDate],
            ]),
          ],
        }),
      ],
      tags: tags ? (tags.tags || []).map((t) => ({ key: t.key || '', value: t.value || '' })) : undefined,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown Redshift id: ${id}`, 400);
}

export const redshiftAdapter: PageServiceAdapter = {
  list,
  detail,
  async action(profile, region, id, action, params) {
    const [kind, name] = splitId(id);
    if (kind !== 'cl') throw httpError('Actions are only available for provisioned clusters', 400);
    const c = provisioned(profile, region);
    if (action === 'snapshot') await c.send(new CreateClusterSnapshotCommand({ ClusterIdentifier: name, SnapshotIdentifier: params.name, ManualSnapshotRetentionPeriod: Number(params.retention || '-1') }));
    else if (action === 'pause') await c.send(new PauseClusterCommand({ ClusterIdentifier: name }));
    else if (action === 'resume') await c.send(new ResumeClusterCommand({ ClusterIdentifier: name }));
    else if (action === 'reboot') await c.send(new RebootClusterCommand({ ClusterIdentifier: name }));
    else throw httpError('action must be snapshot, pause, resume or reboot', 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (splitId(id)[0] === 'wg') await serverless(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ key, value }] }));
    else await provisioned(profile, region).send(new CreateTagsCommand({ ResourceName: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (splitId(id)[0] === 'wg') await serverless(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
    else await provisioned(profile, region).send(new DeleteTagsCommand({ ResourceName: arn, TagKeys: [key] }));
  },
};
