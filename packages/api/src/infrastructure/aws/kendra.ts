import {
  KendraClient,
  ListIndicesCommand,
  DescribeIndexCommand,
  ListDataSourcesCommand as KdListDataSources,
  ListFaqsCommand,
  ListTagsForResourceCommand as KdListTags,
  TagResourceCommand as KdTag,
  UntagResourceCommand as KdUntag,
} from '@aws-sdk/client-kendra';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, accountId, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Kendra. */
const kd = (p: string, r: string) => new KendraClient(clientConfig(p, r));
const indexArn = async (p: string, r: string, indexId: string) => `arn:aws:kendra:${r}:${await accountId(p, r)}:index/${indexId}`;

export const kendraAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const indices = await pageAll((NextToken) => kd(profile, region).send(new ListIndicesCommand({ NextToken })), (r) => r.IndexConfigurationSummaryItems, (r) => r.NextToken);
    return indices.map((i) => ({ id: `idx:${i.Id}`, name: i.Name || i.Id || '', status: i.Status, info: i.Edition })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, indexId] = splitId(id);
    if (kind !== 'idx') throw httpError(`Unknown Kendra page: ${id}`, 400);
    const c = kd(profile, region);
    const i = await c.send(new DescribeIndexCommand({ Id: indexId }));
    const arn = await indexArn(profile, region, indexId);
    const errors: string[] = [];
    const parts = await settle(
      {
        sources: pageAll((NextToken) => c.send(new KdListDataSources({ IndexId: indexId, NextToken })), (r) => r.SummaryItems, (r) => r.NextToken),
        faqs: pageAll((NextToken) => c.send(new ListFaqsCommand({ IndexId: indexId, NextToken })), (r) => r.FaqSummaryItems, (r) => r.NextToken),
        tags: c.send(new KdListTags({ ResourceARN: arn })),
      },
      errors,
    );
    const stats = i.IndexStatistics;
    return {
      id,
      title: i.Name || indexId,
      subtitle: `Kendra ${i.Edition ?? ''} index`,
      status: i.Status,
      arn,
      tabs: [
        tab('Details', {
          sections: [
            section('Index', [
              ['Index ID', i.Id],
              ['Edition', i.Edition],
              ['Status', i.Status],
              ['Error', i.ErrorMessage],
              ['Description', i.Description],
              ['Documents', stats?.TextDocumentStatistics?.IndexedTextDocumentsCount],
              ['Indexed size', stats?.TextDocumentStatistics?.IndexedTextBytes !== undefined ? `${(stats.TextDocumentStatistics.IndexedTextBytes / 1e6).toFixed(1)} MB` : undefined],
              ['FAQ questions', stats?.FaqStatistics?.IndexedQuestionAnswersCount],
              ['Extra capacity (storage / query)', i.CapacityUnits ? `${i.CapacityUnits.StorageCapacityUnits} / ${i.CapacityUnits.QueryCapacityUnits}` : undefined],
              ['User context', i.UserContextPolicy],
              ['Role', i.RoleArn],
              ['KMS key', i.ServerSideEncryptionConfiguration?.KmsKeyId],
              ['Created', i.CreatedAt],
              ['Updated', i.UpdatedAt],
            ]),
          ],
        }),
        tab('Data sources & FAQs', {
          tables: [
            table(['Data source', 'Type', 'Status', 'Language', 'Updated'], (parts.sources || []).map((s) => [s.Name, s.Type, s.Status, s.LanguageCode, s.UpdatedAt]), { title: 'Data sources', statusColumn: 2, emptyMessage: 'No data sources' }),
            table(['FAQ', 'Format', 'Status', 'Language', 'Updated'], (parts.faqs || []).map((f) => [f.Name, f.FileFormat, f.Status, f.LanguageCode, f.UpdatedAt]), { title: 'FAQs', statusColumn: 2, emptyMessage: 'No FAQs' }),
          ],
        }),
        tab('Fields', {
          tables: [table(['Field', 'Type', 'Searchable', 'Facetable', 'Displayable', 'Sortable'], (i.DocumentMetadataConfigurations || []).map((f) => [f.Name, f.Type, f.Search?.Searchable, f.Search?.Facetable, f.Search?.Displayable, f.Search?.Sortable]), { emptyMessage: 'No custom fields' })],
        }),
      ],
      tags: tagList(parts.tags?.Tags),
      actions: [],
      errors,
    };
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await kd(profile, region).send(new KdTag({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await kd(profile, region).send(new KdUntag({ ResourceARN: arn, TagKeys: [key] }));
  },
};
