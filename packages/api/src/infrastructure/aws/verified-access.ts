import {
  DescribeVerifiedAccessInstancesCommand,
  DescribeVerifiedAccessGroupsCommand,
  DescribeVerifiedAccessEndpointsCommand,
  DescribeVerifiedAccessTrustProvidersCommand,
  DescribeVerifiedAccessInstanceLoggingConfigurationsCommand,
  GetVerifiedAccessGroupPolicyCommand,
  GetVerifiedAccessEndpointPolicyCommand,
} from '@aws-sdk/client-ec2';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';
import { ec2, describeAll, nameTag, ec2TagFns } from './ec2-pages.js';

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = ec2(profile, region);
  const [inst, groups, endpoints, providers] = await Promise.all([
    describeAll((NextToken) => c.send(new DescribeVerifiedAccessInstancesCommand({ NextToken })), (r) => r.VerifiedAccessInstances),
    describeAll((NextToken) => c.send(new DescribeVerifiedAccessGroupsCommand({ NextToken })), (r) => r.VerifiedAccessGroups),
    describeAll((NextToken) => c.send(new DescribeVerifiedAccessEndpointsCommand({ NextToken })), (r) => r.VerifiedAccessEndpoints),
    describeAll((NextToken) => c.send(new DescribeVerifiedAccessTrustProvidersCommand({ NextToken })), (r) => r.VerifiedAccessTrustProviders),
  ]);
  return [
    ...inst.map((i) => ({ id: `vai:${i.VerifiedAccessInstanceId}`, name: nameTag(i.Tags) ?? i.VerifiedAccessInstanceId ?? '', group: 'Instances', info: [i.Description, `${i.VerifiedAccessTrustProviders?.length ?? 0} trust providers`].filter(Boolean).join(' · ') })),
    ...groups.map((g) => ({ id: `vag:${g.VerifiedAccessGroupId}`, name: nameTag(g.Tags) ?? g.VerifiedAccessGroupId ?? '', group: 'Groups', info: [g.Description, g.VerifiedAccessInstanceId].filter(Boolean).join(' · ') })),
    ...endpoints.map((e) => ({ id: `vae:${e.VerifiedAccessEndpointId}`, name: nameTag(e.Tags) ?? e.ApplicationDomain ?? e.VerifiedAccessEndpointId ?? '', group: 'Endpoints', status: e.Status?.Code, info: [e.ApplicationDomain, e.EndpointType].filter(Boolean).join(' · ') })),
    ...providers.map((p) => ({ id: `vatp:${p.VerifiedAccessTrustProviderId}`, name: nameTag(p.Tags) ?? p.VerifiedAccessTrustProviderId ?? '', group: 'Trust providers', info: [p.TrustProviderType, p.UserTrustProviderType ?? p.DeviceTrustProviderType].filter(Boolean).join(' · ') })),
  ];
}

const policyTab = (enabled?: boolean, doc?: string): PageTab => tab('Policy', doc ? { text: doc } : { emptyMessage: enabled ? 'Policy enabled with an empty document' : 'No policy (access is evaluated by the group / instance)' });

async function instancePage(profile: string, region: string, id: string, vaId: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const i = (await c.send(new DescribeVerifiedAccessInstancesCommand({ VerifiedAccessInstanceIds: [vaId] }))).VerifiedAccessInstances?.[0];
  if (!i) throw httpError(`Verified Access instance not found: ${vaId}`, 404);
  const errors: string[] = [];
  const { logs, groups } = await settle(
    {
      logs: c.send(new DescribeVerifiedAccessInstanceLoggingConfigurationsCommand({ VerifiedAccessInstanceIds: [vaId] })),
      groups: describeAll((NextToken) => c.send(new DescribeVerifiedAccessGroupsCommand({ VerifiedAccessInstanceId: vaId, NextToken })), (r) => r.VerifiedAccessGroups),
    },
    errors,
  );
  const al = logs?.LoggingConfigurations?.[0]?.AccessLogs;
  return {
    id,
    title: nameTag(i.Tags) ?? vaId,
    subtitle: i.Description || 'Verified Access instance',
    tabs: [
      tab('Details', {
        sections: [
          section('Instance', [['Instance ID', vaId], ['Description', i.Description], ['FIPS', i.FipsEnabled], ['Created', i.CreationTime], ['Updated', i.LastUpdatedTime]]),
          section('Access logging', [
            ['S3', al?.S3?.Enabled ? al.S3.BucketName : false],
            ['CloudWatch Logs', al?.CloudWatchLogs?.Enabled ? al.CloudWatchLogs.LogGroup : false],
            ['Kinesis Data Firehose', al?.KinesisDataFirehose?.Enabled ? al.KinesisDataFirehose.DeliveryStream : false],
            ['Log version', al?.LogVersion],
            ['Include trust context', al?.IncludeTrustContext],
          ]),
        ],
      }),
      tab('Trust providers', {
        tables: [
          table(['Trust provider', 'Type', 'User / device type', 'Description'], (i.VerifiedAccessTrustProviders || []).map((p) => [p.VerifiedAccessTrustProviderId, p.TrustProviderType, p.UserTrustProviderType ?? p.DeviceTrustProviderType, p.Description]), { emptyMessage: 'No trust providers attached' }),
        ],
      }),
      tab('Groups', {
        tables: [table(['Group', 'Name', 'Description', 'Created'], (groups || []).map((g) => [g.VerifiedAccessGroupId, nameTag(g.Tags), g.Description, g.CreationTime]), { emptyMessage: 'No groups' })],
      }),
    ],
    tags: tagList(i.Tags),
    actions: [],
    errors,
  };
}

async function groupPage(profile: string, region: string, id: string, groupId: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const g = (await c.send(new DescribeVerifiedAccessGroupsCommand({ VerifiedAccessGroupIds: [groupId] }))).VerifiedAccessGroups?.[0];
  if (!g) throw httpError(`Verified Access group not found: ${groupId}`, 404);
  const errors: string[] = [];
  const { policy, endpoints } = await settle(
    {
      policy: c.send(new GetVerifiedAccessGroupPolicyCommand({ VerifiedAccessGroupId: groupId })),
      endpoints: describeAll((NextToken) => c.send(new DescribeVerifiedAccessEndpointsCommand({ VerifiedAccessGroupId: groupId, NextToken })), (r) => r.VerifiedAccessEndpoints),
    },
    errors,
  );
  return {
    id,
    title: nameTag(g.Tags) ?? groupId,
    subtitle: g.Description || 'Verified Access group',
    arn: g.VerifiedAccessGroupArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Group', [
            ['Group ID', groupId],
            ['Instance', g.VerifiedAccessInstanceId],
            ['Description', g.Description],
            ['Owner', g.Owner],
            ['Policy enabled', policy?.PolicyEnabled],
            ['Customer managed key', g.SseSpecification?.KmsKeyArn ?? (g.SseSpecification?.CustomerManagedKeyEnabled === false ? 'AWS owned key' : undefined)],
            ['Created', g.CreationTime],
            ['Updated', g.LastUpdatedTime],
          ]),
        ],
      }),
      tab('Endpoints', {
        tables: [table(['Endpoint', 'Application domain', 'Type', 'Status'], (endpoints || []).map((e) => [e.VerifiedAccessEndpointId, e.ApplicationDomain, e.EndpointType, e.Status?.Code]), { statusColumn: 3, emptyMessage: 'No endpoints' })],
      }),
      policyTab(policy?.PolicyEnabled, policy?.PolicyDocument),
    ],
    tags: tagList(g.Tags),
    actions: [],
    errors,
  };
}

async function endpointPage(profile: string, region: string, id: string, epId: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const e = (await c.send(new DescribeVerifiedAccessEndpointsCommand({ VerifiedAccessEndpointIds: [epId] }))).VerifiedAccessEndpoints?.[0];
  if (!e) throw httpError(`Verified Access endpoint not found: ${epId}`, 404);
  const errors: string[] = [];
  const { policy } = await settle({ policy: c.send(new GetVerifiedAccessEndpointPolicyCommand({ VerifiedAccessEndpointId: epId })) }, errors);
  const lb = e.LoadBalancerOptions;
  const eni = e.NetworkInterfaceOptions;
  return {
    id,
    title: nameTag(e.Tags) ?? e.ApplicationDomain ?? epId,
    subtitle: e.Description || `${e.EndpointType ?? ''} endpoint`,
    status: e.Status?.Code,
    tabs: [
      tab('Details', {
        sections: [
          section('Endpoint', [
            ['Endpoint ID', epId],
            ['Application domain', e.ApplicationDomain],
            ['Endpoint domain', e.EndpointDomain],
            ['Device validation domain', e.DeviceValidationDomain],
            ['Domain certificate', e.DomainCertificateArn],
            ['Type', e.EndpointType],
            ['Attachment', e.AttachmentType],
            ['Group', e.VerifiedAccessGroupId],
            ['Instance', e.VerifiedAccessInstanceId],
            ['Security groups', e.SecurityGroupIds],
            ['Status', e.Status?.Code],
            ['Status message', e.Status?.Message],
            ['Policy enabled', policy?.PolicyEnabled],
            ['Created', e.CreationTime],
          ]),
          section('Target', [
            ['Load balancer', lb?.LoadBalancerArn],
            ['Subnets', lb?.SubnetIds],
            ['Network interface', eni?.NetworkInterfaceId],
            ['Protocol', lb?.Protocol ?? eni?.Protocol],
            ['Port', lb?.Port ?? eni?.Port],
          ], { copyable: e.EndpointDomain ? [{ label: 'Endpoint domain (CNAME target)', value: e.EndpointDomain }] : undefined }),
        ],
      }),
      policyTab(policy?.PolicyEnabled, policy?.PolicyDocument),
    ],
    tags: tagList(e.Tags),
    actions: [],
    errors,
  };
}

async function providerPage(profile: string, region: string, id: string, tpId: string): Promise<ResourcePage> {
  const c = ec2(profile, region);
  const p = (await c.send(new DescribeVerifiedAccessTrustProvidersCommand({ VerifiedAccessTrustProviderIds: [tpId] }))).VerifiedAccessTrustProviders?.[0];
  if (!p) throw httpError(`Trust provider not found: ${tpId}`, 404);
  // OidcOptions also carries the client secret - only the fields below are read.
  const o = p.OidcOptions;
  return {
    id,
    title: nameTag(p.Tags) ?? tpId,
    subtitle: p.Description || `${p.TrustProviderType ?? ''} trust provider`,
    tabs: [
      tab('Details', {
        sections: [
          section('Trust provider', [
            ['Trust provider ID', tpId],
            ['Type', p.TrustProviderType],
            ['User trust type', p.UserTrustProviderType],
            ['Device trust type', p.DeviceTrustProviderType],
            ['Policy reference name', p.PolicyReferenceName],
            ['Description', p.Description],
            ['Created', p.CreationTime],
            ['Updated', p.LastUpdatedTime],
          ]),
          ...(o ? [section('OIDC', [['Issuer', o.Issuer], ['Authorization endpoint', o.AuthorizationEndpoint], ['Token endpoint', o.TokenEndpoint], ['User info endpoint', o.UserInfoEndpoint], ['Client ID', o.ClientId], ['Scope', o.Scope]])] : []),
          ...(p.DeviceOptions ? [section('Device', [['Tenant ID', p.DeviceOptions.TenantId], ['Public signing key URL', p.DeviceOptions.PublicSigningKeyUrl]])] : []),
        ],
      }),
    ],
    tags: tagList(p.Tags),
    actions: [],
    errors: [],
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, rest] = splitId(id);
  if (kind === 'vai') return instancePage(profile, region, id, rest);
  if (kind === 'vag') return groupPage(profile, region, id, rest);
  if (kind === 'vae') return endpointPage(profile, region, id, rest);
  if (kind === 'vatp') return providerPage(profile, region, id, rest);
  throw httpError(`Unknown Verified Access resource: ${id}`, 400);
}

export const verifiedAccessAdapter: PageServiceAdapter = { list, detail, ...ec2TagFns, countable: (row) => row.id.startsWith('vae:') };
