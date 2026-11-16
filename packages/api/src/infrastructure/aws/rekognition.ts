import {
  RekognitionClient,
  ListCollectionsCommand,
  DescribeCollectionCommand,
  ListStreamProcessorsCommand,
  DescribeStreamProcessorCommand,
  DescribeProjectsCommand,
  DescribeProjectVersionsCommand,
  ListTagsForResourceCommand as RkListTags,
  TagResourceCommand as RkTag,
  UntagResourceCommand as RkUntag,
} from '@aws-sdk/client-rekognition';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, lastPart, clientConfig, byName, basicPage } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Rekognition. */
const rk = (p: string, r: string) => new RekognitionClient(clientConfig(p, r));

export const rekognitionAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = rk(profile, region);
    const [cols, sps, projects] = await Promise.all([
      pageAll((NextToken) => c.send(new ListCollectionsCommand({ NextToken })), (r) => r.CollectionIds, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListStreamProcessorsCommand({ NextToken })), (r) => r.StreamProcessors, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new DescribeProjectsCommand({ NextToken })), (r) => r.ProjectDescriptions, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      ...cols.map((x) => ({ id: `col:${x}`, name: x, group: 'Face collections' })).sort(byName),
      ...sps.map((s) => ({ id: `sp:${s.Name}`, name: s.Name || '', group: 'Stream processors', status: s.Status })).sort(byName),
      ...projects.map((p) => ({ id: `proj:${p.ProjectArn}`, name: p.ProjectArn?.split('/')[1] || '', group: 'Custom Labels projects', status: p.Status, info: p.Feature })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = rk(profile, region);
    const [kind, rest] = splitId(id);
    const errors: string[] = [];
    if (kind === 'col') {
      const d = await c.send(new DescribeCollectionCommand({ CollectionId: rest }));
      const { tags } = await settle({ tags: c.send(new RkListTags({ ResourceArn: d.CollectionARN })) }, errors);
      return basicPage(id, rest, 'Face collection', [tab('Details', { sections: [section('Collection', [['Faces', d.FaceCount], ['Users', d.UserCount], ['Face model', d.FaceModelVersion], ['Created', d.CreationTimestamp]])] })], { arn: d.CollectionARN, tags: tagMap(tags?.Tags), errors });
    }
    if (kind === 'sp') {
      const s = await c.send(new DescribeStreamProcessorCommand({ Name: rest }));
      const { tags } = await settle({ tags: c.send(new RkListTags({ ResourceArn: s.StreamProcessorArn })) }, errors);
      return basicPage(
        id,
        rest,
        'Stream processor',
        [
          tab('Details', {
            sections: [
              section('Stream processor', [
                ['Status', s.Status],
                ['Status message', s.StatusMessage],
                ['Input (video stream)', s.Input?.KinesisVideoStream?.Arn],
                ['Output', s.Output?.KinesisDataStream?.Arn ?? (s.Output?.S3Destination && `s3://${s.Output.S3Destination.Bucket}/${s.Output.S3Destination.KeyPrefix ?? ''}`)],
                ['Face search collection', s.Settings?.FaceSearch?.CollectionId],
                ['Label detection', s.Settings?.ConnectedHome?.Labels],
                ['Role', s.RoleArn],
                ['Created', s.CreationTimestamp],
                ['Updated', s.LastUpdateTimestamp],
              ]),
            ],
          }),
        ],
        { status: s.Status, arn: s.StreamProcessorArn, tags: tagMap(tags?.Tags), errors },
      );
    }
    if (kind === 'proj') {
      const p = (await c.send(new DescribeProjectsCommand({ ProjectNames: [rest.split('/')[1] || ''] }))).ProjectDescriptions?.[0];
      if (!p) throw httpError(`Project not found: ${rest}`, 404);
      const parts = await settle({ versions: pageAll((NextToken) => c.send(new DescribeProjectVersionsCommand({ ProjectArn: rest, NextToken })), (r) => r.ProjectVersionDescriptions, (r) => r.NextToken), tags: c.send(new RkListTags({ ResourceArn: rest })) }, errors);
      return basicPage(
        id,
        rest.split('/')[1] || rest,
        `Custom Labels project · ${p.Feature ?? ''}`,
        [
          tab('Details', {
            sections: [section('Project', [['Status', p.Status], ['Feature', p.Feature], ['Auto update', p.AutoUpdate], ['Datasets', (p.Datasets || []).map((d) => `${d.DatasetType}: ${d.Status}`)], ['Created', p.CreationTimestamp]])],
            tables: [
              table(
                ['Version', 'Status', 'F1 score', 'Inference units', 'Training time', 'Created', 'Message'],
                (parts.versions || []).map((v) => [lastPart(v.ProjectVersionArn?.split('/version/')[1]?.split('/')[0]), v.Status, v.EvaluationResult?.F1Score?.toFixed(3), v.MinInferenceUnits, v.BillableTrainingTimeInSeconds !== undefined ? `${Math.round(v.BillableTrainingTimeInSeconds / 60)} min` : undefined, v.CreationTimestamp, v.StatusMessage]),
                { title: 'Model versions', statusColumn: 1, emptyMessage: 'No trained models' },
              ),
            ],
          }),
        ],
        { status: p.Status, arn: rest, tags: tagMap(parts.tags?.Tags), errors },
      );
    }
    throw httpError(`Unknown Rekognition page: ${id}`, 400);
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await rk(profile, region).send(new RkTag({ ResourceArn: arn, Tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await rk(profile, region).send(new RkUntag({ ResourceArn: arn, TagKeys: [key] }));
  },
};
