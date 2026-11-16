import {
  SSMClient,
  DescribeInstanceInformationCommand,
  DescribeInstancePatchStatesCommand,
  DescribeInstancePatchesCommand,
  DescribeInstanceAssociationsStatusCommand,
  DescribeParametersCommand,
  GetParameterCommand,
  GetParameterHistoryCommand,
  ListDocumentsCommand,
  DescribeDocumentCommand,
  GetDocumentCommand,
  DescribeMaintenanceWindowsCommand,
  GetMaintenanceWindowCommand,
  DescribeMaintenanceWindowTargetsCommand,
  DescribeMaintenanceWindowTasksCommand,
  DescribeMaintenanceWindowExecutionsCommand,
  ListAssociationsCommand,
  DescribeAssociationCommand,
  DescribeAssociationExecutionsCommand,
  ListTagsForResourceCommand,
  AddTagsToResourceCommand,
  RemoveTagsFromResourceCommand,
  type ResourceTypeForTagging,
} from '@aws-sdk/client-ssm';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new SSMClient({ region: r, credentials: cachedCredentials(p) });

const PARAMETER_LIMIT = 1000;
const PATCH_LIMIT = 200;

const TAG_TYPES: Record<string, ResourceTypeForTagging> = { mi: 'ManagedInstance', param: 'Parameter', doc: 'Document', mw: 'MaintenanceWindow' };

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [instances, params, docs, windows, assocs] = await Promise.all([
    pageAll((NextToken) => c.send(new DescribeInstanceInformationCommand({ NextToken })), (r) => r.InstanceInformationList, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new DescribeParametersCommand({ NextToken, MaxResults: 50 })), (r) => r.Parameters, (r) => r.NextToken, PARAMETER_LIMIT).catch(() => []),
    pageAll((NextToken) => c.send(new ListDocumentsCommand({ NextToken, Filters: [{ Key: 'Owner', Values: ['Self'] }] })), (r) => r.DocumentIdentifiers, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new DescribeMaintenanceWindowsCommand({ NextToken })), (r) => r.WindowIdentities, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListAssociationsCommand({ NextToken })), (r) => r.Associations, (r) => r.NextToken).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...instances.map((i) => ({ id: `mi:${i.InstanceId}`, name: i.ComputerName || i.Name || i.InstanceId || '', group: 'Managed nodes', status: i.PingStatus, info: [i.InstanceId, i.PlatformName && `${i.PlatformName} ${i.PlatformVersion ?? ''}`.trim(), i.AgentVersion && `agent ${i.AgentVersion}`].filter(Boolean).join(' · ') })).sort(byName),
    ...params.map((p) => ({ id: `param:${p.Name}`, name: p.Name || '', group: 'Parameter Store', info: [p.Type, p.Tier, `v${p.Version}`].filter(Boolean).join(' · ') })).sort(byName),
    ...docs.map((d) => ({ id: `doc:${d.Name}`, name: d.Name || '', group: 'Documents (owned by me)', info: [d.DocumentType, d.DocumentFormat, d.DocumentVersion && `v${d.DocumentVersion}`].filter(Boolean).join(' · ') })).sort(byName),
    ...windows.map((w) => ({ id: `mw:${w.WindowId}`, name: w.Name || w.WindowId || '', group: 'Maintenance windows', status: w.Enabled ? 'ENABLED' : 'DISABLED', info: [w.Schedule, w.NextExecutionTime && `next ${w.NextExecutionTime}`].filter(Boolean).join(' · ') })).sort(byName),
    ...assocs.map((a) => ({ id: `assoc:${a.AssociationId}`, name: a.AssociationName || a.Name || a.AssociationId || '', group: 'State Manager associations', status: a.Overview?.Status, info: [a.Name, a.ScheduleExpression].filter(Boolean).join(' · ') })).sort(byName),
  ];
}

async function instancePage(c: SSMClient, id: string, instanceId: string): Promise<ResourcePage> {
  const i = (await c.send(new DescribeInstanceInformationCommand({ Filters: [{ Key: 'InstanceIds', Values: [instanceId] }] }))).InstanceInformationList?.[0];
  if (!i) throw httpError(`Managed node not found: ${instanceId}`, 404);
  const errors: string[] = [];
  const isHybrid = instanceId.startsWith('mi-');
  const parts = await settle(
    {
      patchState: c.send(new DescribeInstancePatchStatesCommand({ InstanceIds: [instanceId] })),
      patches: pageAll((NextToken) => c.send(new DescribeInstancePatchesCommand({ InstanceId: instanceId, NextToken, Filters: [{ Key: 'State', Values: ['Missing', 'Failed', 'InstalledPendingReboot'] }] })), (r) => r.Patches, (r) => r.NextToken, PATCH_LIMIT),
      assocs: pageAll((NextToken) => c.send(new DescribeInstanceAssociationsStatusCommand({ InstanceId: instanceId, NextToken })), (r) => r.InstanceAssociationStatusInfos, (r) => r.NextToken),
      // EC2 instances are tagged through EC2; only hybrid (mi-) nodes carry SSM tags.
      tags: isHybrid ? c.send(new ListTagsForResourceCommand({ ResourceType: 'ManagedInstance', ResourceId: instanceId })) : Promise.resolve(undefined),
    },
    errors,
  );
  const ps = parts.patchState?.InstancePatchStates?.[0];
  return {
    id,
    title: i.ComputerName || instanceId,
    subtitle: `${i.ResourceType ?? 'Managed node'} · ${instanceId}`,
    status: i.PingStatus,
    tabs: [
      tab('Details', {
        sections: [
          section('Node', [
            ['Instance ID', instanceId],
            ['Computer name', i.ComputerName],
            ['Ping status', i.PingStatus],
            ['Last ping', i.LastPingDateTime],
            ['Platform', `${i.PlatformName ?? ''} ${i.PlatformVersion ?? ''}`.trim()],
            ['Platform type', i.PlatformType],
            ['IP address', i.IPAddress],
            ['Agent version', i.AgentVersion],
            ['Latest agent', i.IsLatestVersion],
            ['IAM role', i.IamRole],
            ['Registered', i.RegistrationDate],
            ['Source', i.SourceType],
          ]),
          section('Patch compliance', [
            ['Baseline', ps?.BaselineId],
            ['Patch group', ps?.PatchGroup],
            ['Last operation', ps?.Operation],
            ['Operation ended', ps?.OperationEndTime],
            ['Installed', ps?.InstalledCount],
            ['Missing', ps?.MissingCount],
            ['Failed', ps?.FailedCount],
            ['Pending reboot', ps?.InstalledPendingRebootCount],
            ['Critical missing', ps?.CriticalNonCompliantCount],
            ['Security missing', ps?.SecurityNonCompliantCount],
          ]),
        ],
      }),
      tab('Patches', {
        tables: [table(['Patch', 'Title', 'Classification', 'Severity', 'State', 'Installed'], (parts.patches || []).map((p) => [p.KBId, p.Title, p.Classification, p.Severity, p.State, p.InstalledTime]), { statusColumn: 4, title: 'Missing, failed or pending reboot', emptyMessage: 'Nothing missing (or never scanned)' })],
      }),
      tab('Associations', {
        tables: [table(['Association', 'Document', 'Status', 'Detailed status', 'Executed'], (parts.assocs || []).map((a) => [a.AssociationName || a.AssociationId, a.Name, a.Status, a.DetailedStatus, a.ExecutionDate]), { statusColumn: 2, emptyMessage: 'No associations' })],
      }),
    ],
    tags: isHybrid ? tagList(parts.tags?.TagList) : undefined,
    actions: [],
    errors,
  };
}

async function parameterPage(c: SSMClient, id: string, name: string): Promise<ResourcePage> {
  const p = (await c.send(new DescribeParametersCommand({ ParameterFilters: [{ Key: 'Name', Option: 'Equals', Values: [name] }] }))).Parameters?.[0];
  if (!p) throw httpError(`Parameter not found: ${name}`, 404);
  const secure = p.Type === 'SecureString';
  const errors: string[] = [];
  const parts = await settle(
    {
      // SecureString values are never fetched, encrypted or not.
      value: secure ? Promise.resolve(undefined) : c.send(new GetParameterCommand({ Name: name, WithDecryption: false })),
      history: pageAll((NextToken) => c.send(new GetParameterHistoryCommand({ Name: name, NextToken, WithDecryption: false })), (r) => r.Parameters, (r) => r.NextToken, 100),
      tags: c.send(new ListTagsForResourceCommand({ ResourceType: 'Parameter', ResourceId: name })),
    },
    errors,
  );
  const value = parts.value?.Parameter?.Value;
  return {
    id,
    title: name,
    subtitle: p.Description || `${p.Type} parameter`,
    arn: parts.value?.Parameter?.ARN,
    tabs: [
      tab('Details', {
        sections: [
          section('Parameter', [
            ['Name', name],
            ['Type', p.Type],
            ['Tier', p.Tier],
            ['Data type', p.DataType],
            ['Version', p.Version],
            ['KMS key', p.KeyId],
            ['Allowed pattern', p.AllowedPattern],
            ['Last modified', p.LastModifiedDate],
            ['Modified by', p.LastModifiedUser],
            ['Policies', (p.Policies || []).map((x) => x.PolicyType)],
          ]),
          secure
            ? section('Value', [['Value', 'SecureString - not shown']], { note: 'SecureString values are never read by this app.' })
            : { title: 'Value', settings: [], copyable: value !== undefined ? [{ label: 'Value', value }] : [] },
        ],
      }),
      tab('History', {
        tables: [
          table(
            secure ? ['Version', 'Modified', 'Modified by', 'Labels'] : ['Version', 'Value', 'Modified', 'Modified by', 'Labels'],
            (parts.history || [])
              .sort((a, b) => (b.Version ?? 0) - (a.Version ?? 0))
              .map((h) => (secure ? [h.Version, h.LastModifiedDate, h.LastModifiedUser, h.Labels] : [h.Version, h.Value, h.LastModifiedDate, h.LastModifiedUser, h.Labels])),
            { emptyMessage: 'No history' },
          ),
        ],
      }),
    ],
    tags: tagList(parts.tags?.TagList),
    actions: [],
    errors,
  };
}

async function documentPage(c: SSMClient, id: string, name: string): Promise<ResourcePage> {
  const d = (await c.send(new DescribeDocumentCommand({ Name: name }))).Document;
  if (!d) throw httpError(`Document not found: ${name}`, 404);
  const errors: string[] = [];
  const parts = await settle({ content: c.send(new GetDocumentCommand({ Name: name })), tags: c.send(new ListTagsForResourceCommand({ ResourceType: 'Document', ResourceId: name })) }, errors);
  const content = parts.content?.Content;
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [
        section('Document', [
          ['Name', d.Name],
          ['Type', d.DocumentType],
          ['Format', d.DocumentFormat],
          ['Status', d.Status],
          ['Default version', d.DefaultVersion],
          ['Latest version', d.LatestVersion],
          ['Version name', d.VersionName],
          ['Schema version', d.SchemaVersion],
          ['Target type', d.TargetType],
          ['Platforms', d.PlatformTypes],
          ['Created', d.CreatedDate],
          ['Owner', d.Owner],
        ]),
      ],
      tables: [table(['Parameter', 'Type', 'Default', 'Description'], (d.Parameters || []).map((p) => [p.Name, p.Type, p.DefaultValue, p.Description]), { title: 'Parameters', emptyMessage: 'No parameters' })],
    }),
  ];
  if (content) tabs.push(d.DocumentFormat === 'JSON' ? tab('Content', { json: content }) : tab('Content', { text: content }));
  return { id, title: name, subtitle: d.Description || `${d.DocumentType} document`, status: d.Status, tabs, tags: tagList(parts.tags?.TagList), actions: [], errors };
}

async function windowPage(c: SSMClient, id: string, windowId: string): Promise<ResourcePage> {
  const w = await c.send(new GetMaintenanceWindowCommand({ WindowId: windowId }));
  const errors: string[] = [];
  const parts = await settle(
    {
      targets: pageAll((NextToken) => c.send(new DescribeMaintenanceWindowTargetsCommand({ WindowId: windowId, NextToken })), (r) => r.Targets, (r) => r.NextToken),
      tasks: pageAll((NextToken) => c.send(new DescribeMaintenanceWindowTasksCommand({ WindowId: windowId, NextToken })), (r) => r.Tasks, (r) => r.NextToken),
      runs: c.send(new DescribeMaintenanceWindowExecutionsCommand({ WindowId: windowId, MaxResults: 25 })),
      tags: c.send(new ListTagsForResourceCommand({ ResourceType: 'MaintenanceWindow', ResourceId: windowId })),
    },
    errors,
  );
  return {
    id,
    title: w.Name || windowId,
    subtitle: w.Description || 'Maintenance window',
    status: w.Enabled ? 'ENABLED' : 'DISABLED',
    tabs: [
      tab('Details', {
        sections: [
          section('Window', [
            ['Window ID', windowId],
            ['Schedule', w.Schedule],
            ['Time zone', w.ScheduleTimezone],
            ['Duration (hours)', w.Duration],
            ['Cutoff (hours)', w.Cutoff],
            ['Allow unregistered targets', w.AllowUnassociatedTargets],
            ['Next run', w.NextExecutionTime],
            ['Start date', w.StartDate],
            ['End date', w.EndDate],
            ['Created', w.CreatedDate],
            ['Modified', w.ModifiedDate],
          ]),
        ],
      }),
      tab('Targets', {
        tables: [table(['Name', 'Type', 'Targets'], (parts.targets || []).map((t) => [t.Name || t.WindowTargetId, t.ResourceType, (t.Targets || []).map((x) => `${x.Key}=${(x.Values || []).join(',')}`)]), { emptyMessage: 'No targets' })],
      }),
      tab('Tasks', {
        tables: [table(['Name', 'Type', 'Task', 'Priority', 'Concurrency', 'Error threshold'], (parts.tasks || []).map((t) => [t.Name || t.WindowTaskId, t.Type, t.TaskArn, t.Priority, t.MaxConcurrency, t.MaxErrors]), { emptyMessage: 'No tasks' })],
      }),
      tab('History', {
        tables: [table(['Execution', 'Status', 'Started', 'Ended', 'Details'], (parts.runs?.WindowExecutions || []).map((e) => [e.WindowExecutionId, e.Status, e.StartTime, e.EndTime, e.StatusDetails]), { statusColumn: 1, emptyMessage: 'Never run' })],
      }),
    ],
    tags: tagList(parts.tags?.TagList),
    actions: [],
    errors,
  };
}

async function associationPage(c: SSMClient, id: string, associationId: string): Promise<ResourcePage> {
  const a = (await c.send(new DescribeAssociationCommand({ AssociationId: associationId }))).AssociationDescription;
  if (!a) throw httpError(`Association not found: ${associationId}`, 404);
  const errors: string[] = [];
  const { runs } = await settle({ runs: c.send(new DescribeAssociationExecutionsCommand({ AssociationId: associationId, MaxResults: 25 })) }, errors);
  return {
    id,
    title: a.AssociationName || a.Name || associationId,
    subtitle: `State Manager association · ${a.Name}`,
    status: a.Overview?.Status,
    tabs: [
      tab('Details', {
        sections: [
          section('Association', [
            ['Association ID', associationId],
            ['Document', a.Name],
            ['Document version', a.DocumentVersion],
            ['Schedule', a.ScheduleExpression],
            ['Status', a.Overview?.Status],
            ['Detailed status', a.Overview?.DetailedStatus],
            ['Compliance severity', a.ComplianceSeverity],
            ['Concurrency', a.MaxConcurrency],
            ['Error threshold', a.MaxErrors],
            ['Output bucket', a.OutputLocation?.S3Location?.OutputS3BucketName],
            ['Last run', a.LastExecutionDate],
            ['Last successful run', a.LastSuccessfulExecutionDate],
            ['Created', a.Date],
          ]),
        ],
        tables: [table(['Key', 'Values'], (a.Targets || []).map((t) => [t.Key, t.Values]), { title: 'Targets', emptyMessage: 'No targets' })],
      }),
      tab('History', {
        tables: [table(['Execution', 'Status', 'Detailed status', 'Created', 'Resources'], (runs?.AssociationExecutions || []).map((e) => [e.ExecutionId, e.Status, e.DetailedStatus, e.CreatedTime, e.ResourceCountByStatus]), { statusColumn: 1, emptyMessage: 'Never run' })],
      }),
    ],
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'mi') return instancePage(c, id, rest);
  if (kind === 'param') return parameterPage(c, id, rest);
  if (kind === 'doc') return documentPage(c, id, rest);
  if (kind === 'mw') return windowPage(c, id, rest);
  if (kind === 'assoc') return associationPage(c, id, rest);
  throw httpError(`Unknown Systems Manager page: ${id}`, 400);
}

function tagTarget(id: string) {
  const [kind, rest] = splitId(id);
  const ResourceType = TAG_TYPES[kind];
  if (!ResourceType || (kind === 'mi' && !rest.startsWith('mi-'))) throw httpError('This resource is tagged elsewhere (EC2 instances are tagged in EC2)', 400);
  return { ResourceType, ResourceId: rest };
}

export const ssmAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new AddTagsToResourceCommand({ ...tagTarget(id), Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile, region).send(new RemoveTagsFromResourceCommand({ ...tagTarget(id), TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('mi:') || row.id.startsWith('param:'),
};
