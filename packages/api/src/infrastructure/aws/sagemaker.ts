import {
  SageMakerClient,
  ListEndpointsCommand,
  DescribeEndpointCommand,
  DescribeEndpointConfigCommand,
  ListNotebookInstancesCommand,
  DescribeNotebookInstanceCommand,
  ListDomainsCommand,
  DescribeDomainCommand,
  ListUserProfilesCommand,
  ListAppsCommand,
  ListPipelinesCommand,
  DescribePipelineCommand,
  ListPipelineExecutionsCommand,
  ListTrainingJobsCommand,
  DescribeTrainingJobCommand,
  ListModelsCommand,
  DescribeModelCommand,
  ListTagsCommand,
  AddTagsCommand,
  DeleteTagsCommand,
} from '@aws-sdk/client-sagemaker';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new SageMakerClient({ region: r, credentials: cachedCredentials(p) });

const JOB_LIMIT = 50;
const MODEL_LIMIT = 200;
/** Container environment / hyperparameter keys whose values are never shown. */
const SECRET_KEY = /pass(word)?|secret|token|credential|private.?key|api.?key|\bkey\b/i;
const masked = (env?: Record<string, string>) => Object.entries(env || {}).map(([k, v]) => [k, SECRET_KEY.test(k) ? '•••• (hidden)' : v]);
const tags = (c: SageMakerClient, ResourceArn?: string) => (ResourceArn ? pageAll((NextToken) => c.send(new ListTagsCommand({ ResourceArn, NextToken })), (r) => r.Tags, (r) => r.NextToken) : Promise.resolve([]));
const minutes = (s?: number) => (s === undefined ? undefined : s >= 3600 ? `${(s / 3600).toFixed(1)} h` : `${Math.round(s / 60)} min`);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [eps, nbs, doms, pipes, jobs, models] = await Promise.all([
    pageAll((NextToken) => c.send(new ListEndpointsCommand({ NextToken })), (r) => r.Endpoints, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListNotebookInstancesCommand({ NextToken })), (r) => r.NotebookInstances, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListDomainsCommand({ NextToken })), (r) => r.Domains, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListPipelinesCommand({ NextToken })), (r) => r.PipelineSummaries, (r) => r.NextToken).catch(() => []),
    c.send(new ListTrainingJobsCommand({ MaxResults: JOB_LIMIT, SortBy: 'CreationTime', SortOrder: 'Descending' })).then((r) => r.TrainingJobSummaries || []).catch(() => []),
    pageAll((NextToken) => c.send(new ListModelsCommand({ NextToken, SortBy: 'CreationTime', SortOrder: 'Descending' })), (r) => r.Models, (r) => r.NextToken, MODEL_LIMIT).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...eps.map((e) => ({ id: `ep:${e.EndpointName}`, name: e.EndpointName || '', group: 'Endpoints', status: e.EndpointStatus })).sort(byName),
    ...nbs.map((n) => ({ id: `nb:${n.NotebookInstanceName}`, name: n.NotebookInstanceName || '', group: 'Notebook instances', status: n.NotebookInstanceStatus, info: n.InstanceType })).sort(byName),
    ...doms.map((d) => ({ id: `dom:${d.DomainId}`, name: d.DomainName || d.DomainId || '', group: 'Studio domains', status: d.Status, info: d.DomainId })).sort(byName),
    ...pipes.map((p) => ({ id: `pipe:${p.PipelineName}`, name: p.PipelineDisplayName || p.PipelineName || '', group: 'Pipelines', info: p.LastExecutionTime && `last run ${p.LastExecutionTime.toISOString().slice(0, 16).replace('T', ' ')}` })).sort(byName),
    ...jobs.map((j) => ({ id: `job:${j.TrainingJobName}`, name: j.TrainingJobName || '', group: `Training jobs (last ${JOB_LIMIT})`, status: j.TrainingJobStatus, info: j.CreationTime?.toISOString().slice(0, 16).replace('T', ' ') })),
    ...models.map((m) => ({ id: `model:${m.ModelName}`, name: m.ModelName || '', group: 'Models', info: m.CreationTime?.toISOString().slice(0, 10) })),
  ];
}

async function endpointPage(c: SageMakerClient, id: string, name: string): Promise<ResourcePage> {
  const e = await c.send(new DescribeEndpointCommand({ EndpointName: name }));
  const errors: string[] = [];
  const parts = await settle({ config: e.EndpointConfigName ? c.send(new DescribeEndpointConfigCommand({ EndpointConfigName: e.EndpointConfigName })) : Promise.resolve(undefined), tags: tags(c, e.EndpointArn) }, errors);
  const configured = new Map((parts.config?.ProductionVariants || []).map((v) => [v.VariantName, v]));
  return {
    id,
    title: name,
    subtitle: 'SageMaker endpoint',
    status: e.EndpointStatus,
    arn: e.EndpointArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Endpoint', [
            ['Status', e.EndpointStatus],
            ['Failure', e.FailureReason],
            ['Endpoint config', e.EndpointConfigName],
            ['Data capture', e.DataCaptureConfig?.EnableCapture ? `${e.DataCaptureConfig.CurrentSamplingPercentage}% → ${e.DataCaptureConfig.DestinationS3Uri}` : false],
            ['Async inference', e.AsyncInferenceConfig?.OutputConfig?.S3OutputPath],
            ['KMS key', parts.config?.KmsKeyId],
            ['Created', e.CreationTime],
            ['Modified', e.LastModifiedTime],
          ]),
        ],
        tables: [
          table(
            ['Variant', 'Model', 'Instance type', 'Instances', 'Weight', 'Serverless', 'Status'],
            (e.ProductionVariants || []).map((v) => {
              const cfg = configured.get(v.VariantName);
              return [
                v.VariantName,
                cfg?.ModelName,
                cfg?.InstanceType,
                v.CurrentInstanceCount !== undefined ? `${v.CurrentInstanceCount} (desired ${v.DesiredInstanceCount ?? '-'})` : undefined,
                v.CurrentWeight,
                v.CurrentServerlessConfig ? `${v.CurrentServerlessConfig.MemorySizeInMB} MB · max ${v.CurrentServerlessConfig.MaxConcurrency}` : undefined,
                (v.VariantStatus || []).map((s) => s.Status).join(', ') || 'InService',
              ];
            }),
            { title: 'Production variants', emptyMessage: 'No variants' },
          ),
        ],
      }),
    ],
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function notebookPage(c: SageMakerClient, id: string, name: string): Promise<ResourcePage> {
  const n = await c.send(new DescribeNotebookInstanceCommand({ NotebookInstanceName: name }));
  const errors: string[] = [];
  const { t } = await settle({ t: tags(c, n.NotebookInstanceArn) }, errors);
  return {
    id,
    title: name,
    subtitle: `${n.InstanceType ?? ''} notebook instance`,
    status: n.NotebookInstanceStatus,
    arn: n.NotebookInstanceArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Notebook instance', [
            ['Status', n.NotebookInstanceStatus],
            ['Failure', n.FailureReason],
            ['Instance type', n.InstanceType],
            ['Platform', n.PlatformIdentifier],
            ['Volume (GB)', n.VolumeSizeInGB],
            ['Root access', n.RootAccess],
            ['Direct internet access', n.DirectInternetAccess],
            ['Lifecycle config', n.NotebookInstanceLifecycleConfigName],
            ['Default repository', n.DefaultCodeRepository],
            ['Additional repositories', n.AdditionalCodeRepositories],
            ['Subnet', n.SubnetId],
            ['Security groups', n.SecurityGroups],
            ['Role', n.RoleArn],
            ['KMS key', n.KmsKeyId],
            ['URL', n.Url && `https://${n.Url}`],
            ['Created', n.CreationTime],
            ['Modified', n.LastModifiedTime],
          ]),
        ],
      }),
    ],
    tags: tagList(t),
    actions: [],
    errors,
  };
}

async function domainPage(c: SageMakerClient, id: string, domainId: string): Promise<ResourcePage> {
  const d = await c.send(new DescribeDomainCommand({ DomainId: domainId }));
  const errors: string[] = [];
  const parts = await settle(
    {
      users: pageAll((NextToken) => c.send(new ListUserProfilesCommand({ DomainIdEquals: domainId, NextToken })), (r) => r.UserProfiles, (r) => r.NextToken),
      apps: pageAll((NextToken) => c.send(new ListAppsCommand({ DomainIdEquals: domainId, NextToken })), (r) => r.Apps, (r) => r.NextToken, 200),
      tags: tags(c, d.DomainArn),
    },
    errors,
  );
  return {
    id,
    title: d.DomainName || domainId,
    subtitle: 'SageMaker Studio domain',
    status: d.Status,
    arn: d.DomainArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Domain', [
            ['Domain ID', d.DomainId],
            ['Status', d.Status],
            ['Failure', d.FailureReason],
            ['Auth mode', d.AuthMode],
            ['Network access', d.AppNetworkAccessType],
            ['VPC', d.VpcId],
            ['Subnets', d.SubnetIds],
            ['Home EFS', d.HomeEfsFileSystemId],
            ['Default execution role', d.DefaultUserSettings?.ExecutionRole],
            ['KMS key', d.KmsKeyId],
            ['Created', d.CreationTime],
            ['Modified', d.LastModifiedTime],
          ]),
          ...(d.Url ? [{ title: 'Studio', settings: [], copyable: [{ label: 'URL', value: d.Url }] }] : []),
        ],
      }),
      tab('User profiles', {
        tables: [table(['User profile', 'Status', 'Created', 'Modified'], (parts.users || []).map((u) => [u.UserProfileName, u.Status, u.CreationTime, u.LastModifiedTime]), { statusColumn: 1, emptyMessage: 'No user profiles' })],
      }),
      tab('Apps', {
        tables: [table(['App', 'Type', 'User / space', 'Status', 'Instance', 'Created'], (parts.apps || []).map((a) => [a.AppName, a.AppType, a.UserProfileName ?? a.SpaceName, a.Status, a.ResourceSpec?.InstanceType, a.CreationTime]), { statusColumn: 3, emptyMessage: 'No apps' })],
      }),
    ],
    tags: tagList(parts.tags),
    actions: [],
    errors,
  };
}

async function pipelinePage(c: SageMakerClient, id: string, name: string): Promise<ResourcePage> {
  const p = await c.send(new DescribePipelineCommand({ PipelineName: name }));
  const errors: string[] = [];
  const parts = await settle({ runs: c.send(new ListPipelineExecutionsCommand({ PipelineName: name, MaxResults: 25, SortBy: 'CreationTime', SortOrder: 'Descending' })), tags: tags(c, p.PipelineArn) }, errors);
  let definition: string | undefined;
  try {
    definition = p.PipelineDefinition ? JSON.stringify(JSON.parse(p.PipelineDefinition), null, 2) : undefined;
  } catch {
    definition = p.PipelineDefinition;
  }
  const tabs: PageTab[] = [
    tab('Details', {
      sections: [section('Pipeline', [['Name', p.PipelineName], ['Display name', p.PipelineDisplayName], ['Description', p.PipelineDescription], ['Status', p.PipelineStatus], ['Role', p.RoleArn], ['Parallelism', p.ParallelismConfiguration?.MaxParallelExecutionSteps], ['Created', p.CreationTime], ['Modified', p.LastModifiedTime], ['Last run', p.LastRunTime]])],
    }),
    tab('Executions', {
      tables: [table(['Execution', 'Status', 'Started', 'Display name', 'Failure'], (parts.runs?.PipelineExecutionSummaries || []).map((r) => [lastPart(r.PipelineExecutionArn), r.PipelineExecutionStatus, r.StartTime, r.PipelineExecutionDisplayName, r.PipelineExecutionFailureReason]), { statusColumn: 1, title: 'Last 25 executions', emptyMessage: 'Never run' })],
    }),
  ];
  if (definition) tabs.push(tab('Definition', { json: definition }));
  return { id, title: p.PipelineDisplayName || name, subtitle: 'SageMaker pipeline', status: p.PipelineStatus, arn: p.PipelineArn, tabs, tags: tagList(parts.tags), actions: [], errors };
}

async function jobPage(c: SageMakerClient, id: string, name: string): Promise<ResourcePage> {
  const j = await c.send(new DescribeTrainingJobCommand({ TrainingJobName: name }));
  const errors: string[] = [];
  const { t } = await settle({ t: tags(c, j.TrainingJobArn) }, errors);
  const rc = j.ResourceConfig;
  return {
    id,
    title: name,
    subtitle: 'Training job',
    status: j.TrainingJobStatus,
    arn: j.TrainingJobArn,
    tabs: [
      tab('Details', {
        sections: [
          section('Training job', [
            ['Status', j.TrainingJobStatus],
            ['Secondary status', j.SecondaryStatus],
            ['Failure', j.FailureReason],
            ['Algorithm / image', j.AlgorithmSpecification?.TrainingImage ?? j.AlgorithmSpecification?.AlgorithmName],
            ['Instances', rc ? `${rc.InstanceCount} × ${rc.InstanceType}` : undefined],
            ['Volume (GB)', rc?.VolumeSizeInGB],
            ['Training time', minutes(j.TrainingTimeInSeconds)],
            ['Billable time', minutes(j.BillableTimeInSeconds)],
            ['Spot training', j.EnableManagedSpotTraining],
            ['Max runtime', minutes(j.StoppingCondition?.MaxRuntimeInSeconds)],
            ['Output', j.OutputDataConfig?.S3OutputPath],
            ['Model artifacts', j.ModelArtifacts?.S3ModelArtifacts],
            ['Role', j.RoleArn],
            ['Created', j.CreationTime],
            ['Ended', j.TrainingEndTime],
          ]),
        ],
        tables: [
          table(['Channel', 'Source', 'Content type'], (j.InputDataConfig || []).map((ch) => [ch.ChannelName, ch.DataSource?.S3DataSource?.S3Uri ?? ch.DataSource?.FileSystemDataSource?.DirectoryPath, ch.ContentType]), { title: 'Input data', emptyMessage: 'No input channels' }),
          table(['Hyperparameter', 'Value'], masked(j.HyperParameters), { title: 'Hyperparameters', emptyMessage: 'No hyperparameters' }),
          table(['Metric', 'Value', 'Time'], (j.FinalMetricDataList || []).map((m) => [m.MetricName, m.Value, m.Timestamp]), { title: 'Final metrics', emptyMessage: 'No metrics' }),
          table(['Variable', 'Value'], masked(j.Environment), { title: 'Environment', emptyMessage: 'No environment variables' }),
        ],
      }),
      tab('Status history', {
        tables: [table(['Status', 'Started', 'Ended', 'Message'], (j.SecondaryStatusTransitions || []).map((s) => [s.Status, s.StartTime, s.EndTime, s.StatusMessage]), { emptyMessage: 'No history' })],
      }),
    ],
    tags: tagList(t),
    actions: [],
    errors,
  };
}

async function modelPage(c: SageMakerClient, id: string, name: string): Promise<ResourcePage> {
  const m = await c.send(new DescribeModelCommand({ ModelName: name }));
  const errors: string[] = [];
  const { t } = await settle({ t: tags(c, m.ModelArn) }, errors);
  const containers = [m.PrimaryContainer, ...(m.Containers || [])].filter(Boolean);
  return {
    id,
    title: name,
    subtitle: 'SageMaker model',
    arn: m.ModelArn,
    tabs: [
      tab('Details', {
        sections: [section('Model', [['Execution role', m.ExecutionRoleArn], ['Network isolation', m.EnableNetworkIsolation], ['VPC subnets', m.VpcConfig?.Subnets], ['Inference mode', m.InferenceExecutionConfig?.Mode], ['Created', m.CreationTime]])],
        tables: [
          table(['Container', 'Image', 'Model data', 'Mode'], containers.map((x, i) => [x?.ContainerHostname ?? `#${i + 1}`, x?.Image, x?.ModelDataUrl, x?.Mode]), { title: 'Containers', emptyMessage: 'No containers' }),
          table(['Container', 'Variable', 'Value'], containers.flatMap((x, i) => masked(x?.Environment).map(([k, v]) => [x?.ContainerHostname ?? `#${i + 1}`, k, v])), { title: 'Environment', emptyMessage: 'No environment variables' }),
        ],
      }),
    ],
    tags: tagList(t),
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  if (kind === 'ep') return endpointPage(c, id, name);
  if (kind === 'nb') return notebookPage(c, id, name);
  if (kind === 'dom') return domainPage(c, id, name);
  if (kind === 'pipe') return pipelinePage(c, id, name);
  if (kind === 'job') return jobPage(c, id, name);
  if (kind === 'model') return modelPage(c, id, name);
  throw httpError(`Unknown SageMaker page: ${id}`, 400);
}

export const sageMakerAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new AddTagsCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await client(profile, region).send(new DeleteTagsCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('ep:') || row.id.startsWith('nb:') || row.id.startsWith('dom:'),
};
