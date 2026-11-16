import {
  AutoScalingClient,
  DescribeAutoScalingGroupsCommand,
  DescribePoliciesCommand,
  DescribeScheduledActionsCommand,
  DescribeScalingActivitiesCommand,
  DescribeInstanceRefreshesCommand,
  UpdateAutoScalingGroupCommand,
  SetInstanceProtectionCommand,
  CreateOrUpdateTagsCommand,
  DeleteTagsCommand,
  type AutoScalingGroup,
} from '@aws-sdk/client-auto-scaling';
import { cachedCredentials } from './credential-cache.js';
import type {
  AsgSummary,
  AsgDetail,
  AsgLaunchSource,
  AsgScaling,
  AsgActivityPage,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): AutoScalingClient {
  return new AutoScalingClient({ region, credentials: cachedCredentials(profile) });
}

function launchSource(g: AutoScalingGroup): AsgLaunchSource {
  if (g.LaunchTemplate) {
    return {
      kind: 'Launch template',
      name: g.LaunchTemplate.LaunchTemplateName,
      id: g.LaunchTemplate.LaunchTemplateId,
      version: g.LaunchTemplate.Version,
    };
  }
  const mixed = g.MixedInstancesPolicy?.LaunchTemplate?.LaunchTemplateSpecification;
  if (mixed) {
    return { kind: 'Mixed instances', name: mixed.LaunchTemplateName, id: mixed.LaunchTemplateId, version: mixed.Version };
  }
  if (g.LaunchConfigurationName) return { kind: 'Launch configuration', name: g.LaunchConfigurationName };
  return { kind: 'Unknown' };
}

function summarize(g: AutoScalingGroup): AsgSummary {
  const instances = g.Instances || [];
  return {
    name: g.AutoScalingGroupName || '',
    arn: g.AutoScalingGroupARN || '',
    desiredCapacity: g.DesiredCapacity ?? 0,
    minSize: g.MinSize ?? 0,
    maxSize: g.MaxSize ?? 0,
    instanceCount: instances.length,
    healthyCount: instances.filter((i) => i.HealthStatus === 'Healthy' && i.LifecycleState === 'InService').length,
    status: g.Status,
    launchSource: launchSource(g),
    availabilityZones: g.AvailabilityZones || [],
    createdTime: g.CreatedTime?.toISOString(),
  };
}

async function fetchGroup(client: AutoScalingClient, name: string): Promise<AutoScalingGroup> {
  const res = await client.send(new DescribeAutoScalingGroupsCommand({ AutoScalingGroupNames: [name] }));
  const group = res.AutoScalingGroups?.[0];
  if (!group) throw new Error(`Auto Scaling group not found: ${name}`);
  return group;
}

export async function listAutoScalingGroups(profile: string, region: string): Promise<AsgSummary[]> {
  const client = createClient(profile, region);
  const groups: AsgSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new DescribeAutoScalingGroupsCommand({ NextToken, MaxRecords: 100 }));
    for (const g of res.AutoScalingGroups || []) groups.push(summarize(g));
    NextToken = res.NextToken;
  } while (NextToken);
  return groups.sort((a, b) => a.name.localeCompare(b.name));
}

export async function getAutoScalingGroupDetail(profile: string, region: string, name: string): Promise<AsgDetail> {
  const client = createClient(profile, region);
  const g = await fetchGroup(client, name);
  const mixed = g.MixedInstancesPolicy;
  const tags = (g.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '', propagateAtLaunch: t.PropagateAtLaunch ?? false }));

  return {
    ...summarize(g),
    subnetIds: (g.VPCZoneIdentifier || '').split(',').map((s) => s.trim()).filter(Boolean),
    healthCheckType: g.HealthCheckType,
    healthCheckGracePeriod: g.HealthCheckGracePeriod,
    defaultCooldown: g.DefaultCooldown,
    defaultInstanceWarmup: g.DefaultInstanceWarmup,
    terminationPolicies: g.TerminationPolicies || [],
    targetGroupArns: g.TargetGroupARNs || [],
    loadBalancerNames: g.LoadBalancerNames || [],
    capacityRebalance: g.CapacityRebalance ?? false,
    maxInstanceLifetime: g.MaxInstanceLifetime,
    newInstancesProtectedFromScaleIn: g.NewInstancesProtectedFromScaleIn ?? false,
    serviceLinkedRoleArn: g.ServiceLinkedRoleARN,
    placementGroup: g.PlacementGroup,
    suspendedProcesses: (g.SuspendedProcesses || []).map((p) => p.ProcessName || '').filter(Boolean),
    enabledMetrics: (g.EnabledMetrics || []).map((m) => m.Metric || '').filter(Boolean),
    instanceTypeOverrides: (mixed?.LaunchTemplate?.Overrides || []).map((o) => o.InstanceType || '').filter(Boolean),
    onDemandBaseCapacity: mixed?.InstancesDistribution?.OnDemandBaseCapacity,
    onDemandPercentageAboveBase: mixed?.InstancesDistribution?.OnDemandPercentageAboveBaseCapacity,
    spotAllocationStrategy: mixed?.InstancesDistribution?.SpotAllocationStrategy,
    instances: (g.Instances || [])
      .map((i) => ({
        instanceId: i.InstanceId || '',
        instanceType: i.InstanceType,
        availabilityZone: i.AvailabilityZone,
        lifecycleState: i.LifecycleState,
        healthStatus: i.HealthStatus,
        launchSource: i.LaunchTemplate
          ? `${i.LaunchTemplate.LaunchTemplateName || i.LaunchTemplate.LaunchTemplateId} (v${i.LaunchTemplate.Version})`
          : i.LaunchConfigurationName,
        protectedFromScaleIn: i.ProtectedFromScaleIn ?? false,
      }))
      .sort((a, b) => a.instanceId.localeCompare(b.instanceId)),
    asgTags: tags,
    tags: tags.map(({ key, value }) => ({ key, value })),
  };
}

export async function getAutoScalingGroupScaling(profile: string, region: string, name: string): Promise<AsgScaling> {
  const client = createClient(profile, region);
  const [policyRes, scheduleRes] = await Promise.all([
    client.send(new DescribePoliciesCommand({ AutoScalingGroupName: name })),
    client.send(new DescribeScheduledActionsCommand({ AutoScalingGroupName: name })),
  ]);

  return {
    policies: (policyRes.ScalingPolicies || []).map((p) => {
      const tt = p.TargetTrackingConfiguration;
      let targetTracking: string | undefined;
      if (tt) {
        const metric = tt.PredefinedMetricSpecification?.PredefinedMetricType
          || tt.CustomizedMetricSpecification?.MetricName
          || 'Custom metric';
        targetTracking = `${metric} = ${tt.TargetValue}`;
      }
      return {
        name: p.PolicyName || '',
        arn: p.PolicyARN || '',
        policyType: p.PolicyType,
        adjustmentType: p.AdjustmentType,
        scalingAdjustment: p.ScalingAdjustment,
        cooldown: p.Cooldown,
        enabled: p.Enabled ?? true,
        targetTracking,
        disableScaleIn: tt?.DisableScaleIn,
        stepAdjustments: (p.StepAdjustments || []).map((s) => {
          const lower = s.MetricIntervalLowerBound ?? '-∞';
          const upper = s.MetricIntervalUpperBound ?? '+∞';
          const adj = s.ScalingAdjustment ?? 0;
          return `[${lower}, ${upper}) → ${adj > 0 ? '+' : ''}${adj}`;
        }),
        alarms: (p.Alarms || []).map((a) => a.AlarmName || '').filter(Boolean),
      };
    }),
    scheduledActions: (scheduleRes.ScheduledUpdateGroupActions || []).map((a) => ({
      name: a.ScheduledActionName || '',
      recurrence: a.Recurrence,
      startTime: a.StartTime?.toISOString(),
      endTime: a.EndTime?.toISOString(),
      minSize: a.MinSize,
      maxSize: a.MaxSize,
      desiredCapacity: a.DesiredCapacity,
      timeZone: a.TimeZone,
    })),
  };
}

export async function getAutoScalingGroupActivity(profile: string, region: string, name: string): Promise<AsgActivityPage> {
  const client = createClient(profile, region);
  const [activityRes, refreshRes] = await Promise.all([
    client.send(new DescribeScalingActivitiesCommand({ AutoScalingGroupName: name, MaxRecords: 50 })),
    client.send(new DescribeInstanceRefreshesCommand({ AutoScalingGroupName: name, MaxRecords: 20 })),
  ]);

  return {
    activities: (activityRes.Activities || []).map((a) => ({
      activityId: a.ActivityId || '',
      description: a.Description,
      cause: a.Cause,
      statusCode: a.StatusCode,
      statusMessage: a.StatusMessage,
      startTime: a.StartTime?.toISOString(),
      endTime: a.EndTime?.toISOString(),
      progress: a.Progress,
    })),
    instanceRefreshes: (refreshRes.InstanceRefreshes || []).map((r) => ({
      instanceRefreshId: r.InstanceRefreshId || '',
      status: r.Status,
      statusReason: r.StatusReason,
      startTime: r.StartTime?.toISOString(),
      endTime: r.EndTime?.toISOString(),
      percentageComplete: r.PercentageComplete,
      instancesToUpdate: r.InstancesToUpdate,
    })),
  };
}

/** The console's "Edit" on Group details: desired / min / max. */
export async function updateCapacity(
  profile: string,
  region: string,
  name: string,
  minSize: number,
  maxSize: number,
  desiredCapacity: number
): Promise<AsgDetail> {
  const client = createClient(profile, region);
  await client.send(new UpdateAutoScalingGroupCommand({
    AutoScalingGroupName: name,
    MinSize: minSize,
    MaxSize: maxSize,
    DesiredCapacity: desiredCapacity,
  }));
  return getAutoScalingGroupDetail(profile, region, name);
}

export async function setInstanceProtection(
  profile: string,
  region: string,
  name: string,
  instanceIds: string[],
  protectedFromScaleIn: boolean
): Promise<AsgDetail> {
  const client = createClient(profile, region);
  await client.send(new SetInstanceProtectionCommand({
    AutoScalingGroupName: name,
    InstanceIds: instanceIds,
    ProtectedFromScaleIn: protectedFromScaleIn,
  }));
  return getAutoScalingGroupDetail(profile, region, name);
}

export async function addAsgTag(
  profile: string,
  region: string,
  name: string,
  key: string,
  value: string,
  propagateAtLaunch = true
): Promise<AsgDetail> {
  const client = createClient(profile, region);
  await client.send(new CreateOrUpdateTagsCommand({
    Tags: [{ ResourceId: name, ResourceType: 'auto-scaling-group', Key: key, Value: value, PropagateAtLaunch: propagateAtLaunch }],
  }));
  return getAutoScalingGroupDetail(profile, region, name);
}

export async function removeAsgTag(profile: string, region: string, name: string, key: string): Promise<AsgDetail> {
  const client = createClient(profile, region);
  await client.send(new DeleteTagsCommand({
    Tags: [{ ResourceId: name, ResourceType: 'auto-scaling-group', Key: key }],
  }));
  return getAutoScalingGroupDetail(profile, region, name);
}
