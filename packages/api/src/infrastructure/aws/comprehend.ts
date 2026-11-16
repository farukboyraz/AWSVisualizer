import {
  ComprehendClient,
  ListDocumentClassifiersCommand,
  DescribeDocumentClassifierCommand,
  ListEntityRecognizersCommand,
  DescribeEntityRecognizerCommand,
  ListEndpointsCommand,
  DescribeEndpointCommand,
  ListFlywheelsCommand,
  DescribeFlywheelCommand,
  ListTagsForResourceCommand as CpListTags,
  TagResourceCommand as CpTag,
  UntagResourceCommand as CpUntag,
} from '@aws-sdk/client-comprehend';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName, basicPage } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Comprehend. */
const cp = (p: string, r: string) => new ComprehendClient(clientConfig(p, r));
const modelName = (arn?: string) => arn?.split('/').slice(1).join('/') || arn || '';

export const comprehendAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = cp(profile, region);
    const [cls, ers, eps, fws] = await Promise.all([
      pageAll((NextToken) => c.send(new ListDocumentClassifiersCommand({ NextToken })), (r) => r.DocumentClassifierPropertiesList, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListEntityRecognizersCommand({ NextToken })), (r) => r.EntityRecognizerPropertiesList, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListEndpointsCommand({ NextToken })), (r) => r.EndpointPropertiesList, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListFlywheelsCommand({ NextToken })), (r) => r.FlywheelSummaryList, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      ...cls.map((x) => ({ id: `cls:${x.DocumentClassifierArn}`, name: modelName(x.DocumentClassifierArn), group: 'Document classifiers', status: x.Status, info: [x.LanguageCode, x.Mode].filter(Boolean).join(' · ') })).sort(byName),
      ...ers.map((x) => ({ id: `er:${x.EntityRecognizerArn}`, name: modelName(x.EntityRecognizerArn), group: 'Entity recognizers', status: x.Status, info: x.LanguageCode })).sort(byName),
      ...eps.map((x) => ({ id: `ep:${x.EndpointArn}`, name: modelName(x.EndpointArn), group: 'Endpoints', status: x.Status, info: `${x.CurrentInferenceUnits ?? 0} inference units` })).sort(byName),
      ...fws.map((x) => ({ id: `fw:${x.FlywheelArn}`, name: modelName(x.FlywheelArn), group: 'Flywheels', status: x.Status, info: x.ModelType })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = cp(profile, region);
    const [kind, arn] = splitId(id);
    const errors: string[] = [];
    const { tags } = await settle({ tags: ['cls', 'er', 'ep', 'fw'].includes(kind) ? c.send(new CpListTags({ ResourceArn: arn })) : Promise.resolve(undefined) }, errors);
    const t = tagList(tags?.Tags);
    if (kind === 'cls') {
      const x = (await c.send(new DescribeDocumentClassifierCommand({ DocumentClassifierArn: arn }))).DocumentClassifierProperties;
      const m = x?.ClassifierMetadata;
      return basicPage(id, modelName(arn), 'Document classifier', [
        tab('Details', {
          sections: [
            section('Classifier', [['Status', x?.Status], ['Message', x?.Message], ['Language', x?.LanguageCode], ['Mode', x?.Mode], ['Version', x?.VersionName], ['Training data', x?.InputDataConfig?.S3Uri], ['Output', x?.OutputDataConfig?.S3Uri], ['Role', x?.DataAccessRoleArn], ['Submitted', x?.SubmitTime], ['Trained', x?.TrainingEndTime]]),
            section('Evaluation', [['Labels', m?.NumberOfLabels], ['Training documents', m?.NumberOfTrainedDocuments], ['Test documents', m?.NumberOfTestDocuments], ['Accuracy', m?.EvaluationMetrics?.Accuracy?.toFixed(3)], ['Precision', m?.EvaluationMetrics?.Precision?.toFixed(3)], ['Recall', m?.EvaluationMetrics?.Recall?.toFixed(3)], ['F1', m?.EvaluationMetrics?.F1Score?.toFixed(3)]]),
          ],
        }),
      ], { status: x?.Status, arn, tags: t, errors });
    }
    if (kind === 'er') {
      const x = (await c.send(new DescribeEntityRecognizerCommand({ EntityRecognizerArn: arn }))).EntityRecognizerProperties;
      const m = x?.RecognizerMetadata;
      return basicPage(id, modelName(arn), 'Entity recognizer', [
        tab('Details', {
          sections: [
            section('Recognizer', [['Status', x?.Status], ['Message', x?.Message], ['Language', x?.LanguageCode], ['Version', x?.VersionName], ['Role', x?.DataAccessRoleArn], ['Submitted', x?.SubmitTime], ['Trained', x?.TrainingEndTime]]),
            section('Evaluation', [['Training documents', m?.NumberOfTrainedDocuments], ['Test documents', m?.NumberOfTestDocuments], ['Precision', m?.EvaluationMetrics?.Precision?.toFixed(3)], ['Recall', m?.EvaluationMetrics?.Recall?.toFixed(3)], ['F1', m?.EvaluationMetrics?.F1Score?.toFixed(3)]]),
          ],
          tables: [table(['Entity type', 'F1', 'Precision', 'Recall'], (m?.EntityTypes || []).map((e) => [e.Type, e.EvaluationMetrics?.F1Score?.toFixed(3), e.EvaluationMetrics?.Precision?.toFixed(3), e.EvaluationMetrics?.Recall?.toFixed(3)]), { title: 'Entity types', emptyMessage: 'No entity types' })],
        }),
      ], { status: x?.Status, arn, tags: t, errors });
    }
    if (kind === 'ep') {
      const x = (await c.send(new DescribeEndpointCommand({ EndpointArn: arn }))).EndpointProperties;
      return basicPage(id, modelName(arn), 'Comprehend endpoint', [
        tab('Details', { sections: [section('Endpoint', [['Status', x?.Status], ['Message', x?.Message], ['Model', x?.ModelArn], ['Inference units', x?.DesiredInferenceUnits !== x?.CurrentInferenceUnits ? `${x?.CurrentInferenceUnits} (changing to ${x?.DesiredInferenceUnits})` : x?.CurrentInferenceUnits], ['Flywheel', x?.FlywheelArn], ['Role', x?.DataAccessRoleArn], ['Created', x?.CreationTime], ['Modified', x?.LastModifiedTime]])] }),
      ], { status: x?.Status, arn, tags: t, errors });
    }
    if (kind === 'fw') {
      const x = (await c.send(new DescribeFlywheelCommand({ FlywheelArn: arn }))).FlywheelProperties;
      return basicPage(id, modelName(arn), 'Flywheel', [
        tab('Details', { sections: [section('Flywheel', [['Status', x?.Status], ['Message', x?.Message], ['Model type', x?.ModelType], ['Active model', x?.ActiveModelArn], ['Data lake', x?.DataLakeS3Uri], ['Latest iteration', x?.LatestFlywheelIteration], ['Role', x?.DataAccessRoleArn], ['Created', x?.CreationTime], ['Modified', x?.LastModifiedTime]])] }),
      ], { status: x?.Status, arn, tags: t, errors });
    }
    throw httpError(`Unknown Comprehend page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await cp(profile, region).send(new CpTag({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await cp(profile, region).send(new CpUntag({ ResourceArn: arn, TagKeys: [key] }));
  },
};
