import {
  QBusinessClient,
  ListApplicationsCommand as QbListApplications,
  GetApplicationCommand as QbGetApplication,
  ListIndicesCommand as QbListIndices,
  ListRetrieversCommand,
  ListWebExperiencesCommand,
  ListDataSourcesCommand as QbListDataSources,
  ListTagsForResourceCommand as QbListTags,
  TagResourceCommand as QbTag,
  UntagResourceCommand as QbUntag,
} from '@aws-sdk/client-qbusiness';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, mapLimited, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Amazon Q Business. */
const qb = (p: string, r: string) => new QBusinessClient(clientConfig(p, r));

export const qBusinessAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const apps = await pageAll((nextToken) => qb(profile, region).send(new QbListApplications({ nextToken })), (r) => r.applications, (r) => r.nextToken);
    return apps.map((a) => ({ id: `app:${a.applicationId}`, name: a.displayName || a.applicationId || '', status: a.status, info: a.identityType })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, applicationId] = splitId(id);
    if (kind !== 'app') throw httpError(`Unknown Amazon Q page: ${id}`, 400);
    const c = qb(profile, region);
    const a = await c.send(new QbGetApplication({ applicationId }));
    const errors: string[] = [];
    const parts = await settle(
      {
        indices: pageAll((nextToken) => c.send(new QbListIndices({ applicationId, nextToken })), (r) => r.indices, (r) => r.nextToken),
        retrievers: pageAll((nextToken) => c.send(new ListRetrieversCommand({ applicationId, nextToken })), (r) => r.retrievers, (r) => r.nextToken),
        web: pageAll((nextToken) => c.send(new ListWebExperiencesCommand({ applicationId, nextToken })), (r) => r.webExperiences, (r) => r.nextToken),
        tags: a.applicationArn ? c.send(new QbListTags({ resourceARN: a.applicationArn })) : Promise.resolve(undefined),
      },
      errors,
    );
    const sources = (await mapLimited(parts.indices || [], 3, (i) => pageAll((nextToken) => c.send(new QbListDataSources({ applicationId, indexId: i.indexId, nextToken })), (r) => r.dataSources, (r) => r.nextToken).then((ds) => ds.map((d) => ({ ...d, index: i.displayName }))).catch(() => []))).flat();
    return {
      id,
      title: a.displayName || applicationId,
      subtitle: 'Amazon Q Business application',
      status: a.status,
      arn: a.applicationArn,
      tabs: [
        tab('Details', {
          sections: [
            section('Application', [
              ['Application ID', a.applicationId],
              ['Status', a.status],
              ['Error', a.error?.errorMessage],
              ['Description', a.description],
              ['Identity', a.identityType],
              ['Identity Center app', a.identityCenterApplicationArn],
              ['File uploads', a.attachmentsConfiguration?.attachmentsControlMode],
              ['Q Apps', a.qAppsConfiguration?.qAppsControlMode],
              ['Role', a.roleArn],
              ['KMS key', a.encryptionConfiguration?.kmsKeyId],
              ['Created', a.createdAt],
              ['Updated', a.updatedAt],
            ]),
            { title: 'Web experiences', settings: [], copyable: (parts.web || []).filter((w) => w.defaultEndpoint).map((w) => ({ label: `${w.webExperienceId} (${w.status})`, value: w.defaultEndpoint! })) },
          ].filter((s) => s.settings.length || ('copyable' in s && s.copyable?.length)),
        }),
        tab('Indexes & data', {
          tables: [
            table(['Index', 'Status', 'Created'], (parts.indices || []).map((i) => [i.displayName, i.status, i.createdAt]), { title: 'Indexes', statusColumn: 1, emptyMessage: 'No indexes' }),
            table(['Retriever', 'Type', 'Status'], (parts.retrievers || []).map((r) => [r.displayName, r.type, r.status]), { title: 'Retrievers', statusColumn: 2, emptyMessage: 'No retrievers' }),
            table(['Data source', 'Index', 'Type', 'Status', 'Updated'], sources.map((d) => [d.displayName, d.index, d.type, d.status, d.updatedAt]), { title: 'Data sources', statusColumn: 3, emptyMessage: 'No data sources' }),
          ],
        }),
      ],
      tags: tagList(parts.tags?.tags?.map((t) => ({ Key: t.key, Value: t.value }))),
      actions: [],
      errors,
    };
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await qb(profile, region).send(new QbTag({ resourceARN: arn, tags: [{ key, value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await qb(profile, region).send(new QbUntag({ resourceARN: arn, tagKeys: [key] }));
  },
};
