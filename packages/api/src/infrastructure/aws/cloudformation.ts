import {
  CloudFormationClient,
  ListStacksCommand,
  DescribeStacksCommand,
  DescribeStackEventsCommand,
  DescribeStackResourcesCommand,
  GetTemplateCommand,
  UpdateTerminationProtectionCommand,
  DeleteStackCommand,
} from '@aws-sdk/client-cloudformation';
import { cachedCredentials } from './credential-cache.js';
import type {
  CloudFormationStack,
  CloudFormationStackDetail,
  CloudFormationStackEvent,
  CloudFormationStackResource,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): CloudFormationClient {
  return new CloudFormationClient({ region, credentials: cachedCredentials(profile) });
}

const ACTIVE_STATUSES = [
  'CREATE_IN_PROGRESS',
  'CREATE_COMPLETE',
  'ROLLBACK_IN_PROGRESS',
  'ROLLBACK_COMPLETE',
  'UPDATE_IN_PROGRESS',
  'UPDATE_COMPLETE_CLEANUP_IN_PROGRESS',
  'UPDATE_COMPLETE',
  'UPDATE_ROLLBACK_IN_PROGRESS',
  'UPDATE_ROLLBACK_COMPLETE',
  'IMPORT_IN_PROGRESS',
  'IMPORT_COMPLETE',
  'IMPORT_ROLLBACK_IN_PROGRESS',
  'IMPORT_ROLLBACK_COMPLETE',
];

export async function listStacks(profile: string, region: string): Promise<CloudFormationStack[]> {
  const client = createClient(profile, region);
  const response = await client.send(new ListStacksCommand({ StackStatusFilter: ACTIVE_STATUSES as any }));

  return (response.StackSummaries || []).map((s) => ({
    stackName: s.StackName || '',
    stackId: s.StackId || '',
    status: s.StackStatus || '',
    creationTime: s.CreationTime?.toISOString(),
    lastUpdatedTime: s.LastUpdatedTime?.toISOString(),
  }));
}

export async function getStackDetail(profile: string, region: string, stackName: string): Promise<CloudFormationStackDetail | undefined> {
  const client = createClient(profile, region);
  const response = await client.send(new DescribeStacksCommand({ StackName: stackName }));
  const stack = response.Stacks?.[0];
  if (!stack) return undefined;

  return {
    stackName: stack.StackName || stackName,
    stackId: stack.StackId || '',
    status: stack.StackStatus || '',
    statusReason: stack.StackStatusReason,
    description: stack.Description,
    creationTime: stack.CreationTime?.toISOString(),
    lastUpdatedTime: stack.LastUpdatedTime?.toISOString(),
    roleArn: stack.RoleARN,
    enableTerminationProtection: stack.EnableTerminationProtection ?? false,
    driftStatus: stack.DriftInformation?.StackDriftStatus,
    parameters: (stack.Parameters || []).map((p) => ({ key: p.ParameterKey || '', value: p.ParameterValue })),
    outputs: (stack.Outputs || []).map((o) => ({
      key: o.OutputKey || '',
      value: o.OutputValue,
      description: o.Description,
      exportName: o.ExportName,
    })),
    tags: (stack.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

export async function getStackEvents(profile: string, region: string, stackName: string, limit = 100): Promise<CloudFormationStackEvent[]> {
  const client = createClient(profile, region);
  const events: CloudFormationStackEvent[] = [];
  let nextToken: string | undefined;

  do {
    const response = await client.send(new DescribeStackEventsCommand({ StackName: stackName, NextToken: nextToken }));
    for (const e of response.StackEvents || []) {
      events.push({
        eventId: e.EventId || '',
        logicalResourceId: e.LogicalResourceId,
        physicalResourceId: e.PhysicalResourceId,
        resourceType: e.ResourceType,
        resourceStatus: e.ResourceStatus,
        resourceStatusReason: e.ResourceStatusReason,
        timestamp: e.Timestamp?.toISOString(),
      });
    }
    nextToken = response.NextToken;
  } while (nextToken && events.length < limit);

  return events.slice(0, limit);
}

export async function getStackResources(profile: string, region: string, stackName: string): Promise<CloudFormationStackResource[]> {
  const client = createClient(profile, region);
  const response = await client.send(new DescribeStackResourcesCommand({ StackName: stackName }));

  return (response.StackResources || []).map((r) => ({
    logicalResourceId: r.LogicalResourceId || '',
    physicalResourceId: r.PhysicalResourceId,
    resourceType: r.ResourceType || '',
    resourceStatus: r.ResourceStatus || '',
    resourceStatusReason: r.ResourceStatusReason,
  }));
}

export async function getStackTemplate(profile: string, region: string, stackName: string): Promise<string> {
  const client = createClient(profile, region);
  const response = await client.send(new GetTemplateCommand({ StackName: stackName }));
  return response.TemplateBody || '';
}

export async function setTerminationProtection(
  profile: string,
  region: string,
  stackName: string,
  enabled: boolean
): Promise<CloudFormationStackDetail | undefined> {
  const client = createClient(profile, region);
  await client.send(new UpdateTerminationProtectionCommand({ StackName: stackName, EnableTerminationProtection: enabled }));
  return getStackDetail(profile, region, stackName);
}

export async function deleteStack(profile: string, region: string, stackName: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteStackCommand({ StackName: stackName }));
}
