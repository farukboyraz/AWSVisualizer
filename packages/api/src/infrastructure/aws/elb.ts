import {
  ElasticLoadBalancingV2Client,
  DescribeLoadBalancersCommand,
  DescribeLoadBalancerAttributesCommand,
  ModifyLoadBalancerAttributesCommand,
  DescribeListenersCommand,
  DescribeRulesCommand,
  DescribeTargetGroupsCommand,
  DescribeTargetHealthCommand,
  DescribeTagsCommand,
  AddTagsCommand,
  RemoveTagsCommand,
  type Action,
  type RuleCondition,
} from '@aws-sdk/client-elastic-load-balancing-v2';
import { cachedCredentials } from './credential-cache.js';
import type { LoadBalancer, LoadBalancerDetail, ElbListener, ElbTargetGroup } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): ElasticLoadBalancingV2Client {
  return new ElasticLoadBalancingV2Client({ region, credentials: cachedCredentials(profile) });
}

export async function listLoadBalancers(profile: string, region: string): Promise<LoadBalancer[]> {
  const client = createClient(profile, region);
  const loadBalancers: LoadBalancer[] = [];
  let marker: string | undefined;
  do {
    const response = await client.send(new DescribeLoadBalancersCommand({ Marker: marker }));
    for (const lb of response.LoadBalancers || []) {
      loadBalancers.push({
        loadBalancerArn: lb.LoadBalancerArn || '',
        loadBalancerName: lb.LoadBalancerName || '',
        dnsName: lb.DNSName,
        type: lb.Type,
        scheme: lb.Scheme,
        state: lb.State?.Code,
        vpcId: lb.VpcId,
        createdTime: lb.CreatedTime?.toISOString(),
      });
    }
    marker = response.NextMarker;
  } while (marker);
  return loadBalancers;
}

export async function getLoadBalancerDetail(profile: string, region: string, arn: string): Promise<LoadBalancerDetail> {
  const client = createClient(profile, region);
  const [lbRes, attrRes, tagRes] = await Promise.all([
    client.send(new DescribeLoadBalancersCommand({ LoadBalancerArns: [arn] })),
    client.send(new DescribeLoadBalancerAttributesCommand({ LoadBalancerArn: arn })),
    client.send(new DescribeTagsCommand({ ResourceArns: [arn] })),
  ]);
  const lb = lbRes.LoadBalancers?.[0];
  if (!lb) throw new Error('Load balancer not found');
  const attributes = (attrRes.Attributes || [])
    .map((a) => ({ key: a.Key || '', value: a.Value || '' }))
    .sort((a, b) => a.key.localeCompare(b.key));

  return {
    loadBalancerArn: lb.LoadBalancerArn || arn,
    loadBalancerName: lb.LoadBalancerName || '',
    dnsName: lb.DNSName,
    canonicalHostedZoneId: lb.CanonicalHostedZoneId,
    type: lb.Type,
    scheme: lb.Scheme,
    state: lb.State?.Code,
    stateReason: lb.State?.Reason,
    vpcId: lb.VpcId,
    ipAddressType: lb.IpAddressType,
    createdTime: lb.CreatedTime?.toISOString(),
    availabilityZones: (lb.AvailabilityZones || []).map((z) => `${z.ZoneName} (${z.SubnetId})`),
    securityGroups: lb.SecurityGroups || [],
    deletionProtection: attributes.find((a) => a.key === 'deletion_protection.enabled')?.value === 'true',
    attributes,
    tags: (tagRes.TagDescriptions?.[0]?.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

/** One readable line per action, the way the console's listener table summarises them. */
function describeAction(a: Action): string {
  switch (a.Type) {
    case 'forward': {
      const groups = a.ForwardConfig?.TargetGroups;
      if (groups && groups.length > 1) {
        return `Forward to ${groups.map((g) => `${g.TargetGroupArn?.split('/')[1]} (${g.Weight ?? 1})`).join(', ')}`;
      }
      return `Forward to ${(a.TargetGroupArn || groups?.[0]?.TargetGroupArn || '').split('/')[1] || '?'}`;
    }
    case 'redirect': {
      const r = a.RedirectConfig;
      return `Redirect ${r?.StatusCode || ''} to ${r?.Protocol || '#{protocol}'}://${r?.Host || '#{host}'}:${r?.Port || '#{port}'}${r?.Path || '/#{path}'}`;
    }
    case 'fixed-response':
      return `Fixed response ${a.FixedResponseConfig?.StatusCode || ''}`;
    case 'authenticate-cognito':
      return 'Authenticate (Cognito)';
    case 'authenticate-oidc':
      return 'Authenticate (OIDC)';
    default:
      return a.Type || 'Unknown';
  }
}

function describeCondition(c: RuleCondition): string {
  const field = c.Field || '';
  const values =
    c.HostHeaderConfig?.Values ||
    c.PathPatternConfig?.Values ||
    c.HttpRequestMethodConfig?.Values ||
    c.SourceIpConfig?.Values ||
    c.HttpHeaderConfig?.Values?.map((v) => `${c.HttpHeaderConfig?.HttpHeaderName}: ${v}`) ||
    c.QueryStringConfig?.Values?.map((v) => `${v.Key ?? ''}=${v.Value ?? ''}`) ||
    c.Values ||
    [];
  return `${field} is ${values.join(' or ')}`;
}

export async function listListeners(profile: string, region: string, arn: string): Promise<ElbListener[]> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeListenersCommand({ LoadBalancerArn: arn }));
  const listeners = res.Listeners || [];

  // Rules are per listener and independent - fetched concurrently.
  const ruleSets = await Promise.all(
    listeners.map((l) =>
      // Network/Gateway listeners have no rules; DescribeRules rejects them.
      l.Protocol === 'HTTP' || l.Protocol === 'HTTPS'
        ? client.send(new DescribeRulesCommand({ ListenerArn: l.ListenerArn })).then((r) => r.Rules || [])
        : Promise.resolve([])
    )
  );

  return listeners
    .map((l, i) => ({
      listenerArn: l.ListenerArn || '',
      protocol: l.Protocol,
      port: l.Port,
      sslPolicy: l.SslPolicy,
      certificates: (l.Certificates || []).map((c) => c.CertificateArn || '').filter(Boolean),
      defaultActions: (l.DefaultActions || []).sort((a, b) => (a.Order ?? 0) - (b.Order ?? 0)).map(describeAction),
      rules: ruleSets[i]
        .map((r) => ({
          ruleArn: r.RuleArn || '',
          priority: r.Priority || '',
          isDefault: r.IsDefault || false,
          conditions: (r.Conditions || []).map(describeCondition),
          actions: (r.Actions || []).sort((a, b) => (a.Order ?? 0) - (b.Order ?? 0)).map(describeAction),
        }))
        .sort((a, b) => (a.isDefault ? 1 : b.isDefault ? -1 : Number(a.priority) - Number(b.priority))),
    }))
    .sort((a, b) => (a.port ?? 0) - (b.port ?? 0));
}

export async function listTargetGroups(profile: string, region: string, arn: string): Promise<ElbTargetGroup[]> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeTargetGroupsCommand({ LoadBalancerArn: arn }));
  const groups = res.TargetGroups || [];
  const healths = await Promise.all(
    groups.map((g) => client.send(new DescribeTargetHealthCommand({ TargetGroupArn: g.TargetGroupArn })))
  );

  return groups.map((g, i) => ({
    targetGroupArn: g.TargetGroupArn || '',
    targetGroupName: g.TargetGroupName || '',
    protocol: g.Protocol,
    port: g.Port,
    targetType: g.TargetType,
    healthCheckProtocol: g.HealthCheckProtocol,
    healthCheckPort: g.HealthCheckPort,
    healthCheckPath: g.HealthCheckPath,
    healthCheckIntervalSeconds: g.HealthCheckIntervalSeconds,
    healthCheckTimeoutSeconds: g.HealthCheckTimeoutSeconds,
    healthyThresholdCount: g.HealthyThresholdCount,
    unhealthyThresholdCount: g.UnhealthyThresholdCount,
    matcher: g.Matcher?.HttpCode || g.Matcher?.GrpcCode,
    targets: (healths[i].TargetHealthDescriptions || []).map((t) => ({
      targetId: t.Target?.Id || '',
      port: t.Target?.Port,
      availabilityZone: t.Target?.AvailabilityZone,
      state: t.TargetHealth?.State,
      reason: t.TargetHealth?.Reason,
      description: t.TargetHealth?.Description,
    })),
  }));
}

export async function setDeletionProtection(profile: string, region: string, arn: string, enabled: boolean): Promise<LoadBalancerDetail> {
  const client = createClient(profile, region);
  await client.send(
    new ModifyLoadBalancerAttributesCommand({
      LoadBalancerArn: arn,
      Attributes: [{ Key: 'deletion_protection.enabled', Value: enabled ? 'true' : 'false' }],
    })
  );
  return getLoadBalancerDetail(profile, region, arn);
}

export async function addLoadBalancerTag(profile: string, region: string, arn: string, key: string, value: string): Promise<LoadBalancerDetail> {
  const client = createClient(profile, region);
  await client.send(new AddTagsCommand({ ResourceArns: [arn], Tags: [{ Key: key, Value: value }] }));
  return getLoadBalancerDetail(profile, region, arn);
}

export async function removeLoadBalancerTag(profile: string, region: string, arn: string, key: string): Promise<LoadBalancerDetail> {
  const client = createClient(profile, region);
  await client.send(new RemoveTagsCommand({ ResourceArns: [arn], TagKeys: [key] }));
  return getLoadBalancerDetail(profile, region, arn);
}
