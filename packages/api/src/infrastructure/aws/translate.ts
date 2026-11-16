import {
  TranslateClient,
  ListTerminologiesCommand,
  GetTerminologyCommand,
  ListParallelDataCommand,
  GetParallelDataCommand,
  ListTextTranslationJobsCommand,
  ListTagsForResourceCommand as TlListTags,
  TagResourceCommand as TlTag,
  UntagResourceCommand as TlUntag,
} from '@aws-sdk/client-translate';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName, basicPage } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Translate. */
const tl = (p: string, r: string) => new TranslateClient(clientConfig(p, r));

export const translateAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = tl(profile, region);
    const [terms, pds] = await Promise.all([
      pageAll((NextToken) => c.send(new ListTerminologiesCommand({ NextToken })), (r) => r.TerminologyPropertiesList, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListParallelDataCommand({ NextToken })), (r) => r.ParallelDataPropertiesList, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      { id: 'jobs:', name: 'Batch translation jobs', group: 'Jobs', info: 'Most recent jobs' },
      ...terms.map((t) => ({ id: `term:${t.Name}`, name: t.Name || '', group: 'Custom terminologies', info: `${t.SourceLanguageCode} → ${(t.TargetLanguageCodes || []).join(', ')} · ${t.TermCount ?? 0} terms` })).sort(byName),
      ...pds.map((p) => ({ id: `pd:${p.Name}`, name: p.Name || '', group: 'Parallel data', status: p.Status, info: `${p.SourceLanguageCode} → ${(p.TargetLanguageCodes || []).join(', ')}` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = tl(profile, region);
    const [kind, name] = splitId(id);
    const errors: string[] = [];
    if (kind === 'jobs') {
      const jobs = await pageAll((NextToken) => c.send(new ListTextTranslationJobsCommand({ NextToken })), (r) => r.TextTranslationJobPropertiesList, (r) => r.NextToken, 100);
      return basicPage(id, 'Batch translation jobs', 'Asynchronous document translation', [
        tab('Jobs', {
          tables: [
            table(['Job', 'Status', 'Languages', 'Submitted', 'Ended', 'Documents (ok / failed)', 'Message'], jobs.map((j) => [j.JobName || j.JobId, j.JobStatus, `${j.SourceLanguageCode} → ${(j.TargetLanguageCodes || []).join(', ')}`, j.SubmittedTime, j.EndTime, `${j.JobDetails?.TranslatedDocumentsCount ?? 0} / ${j.JobDetails?.DocumentsWithErrorsCount ?? 0}`, j.Message]), {
              statusColumn: 1,
              emptyMessage: 'No batch translation jobs',
            }),
          ],
        }),
      ]);
    }
    if (kind === 'term') {
      // TerminologyDataLocation is a presigned download link - not shown.
      const t = (await c.send(new GetTerminologyCommand({ Name: name }))).TerminologyProperties;
      const { tags } = await settle({ tags: t?.Arn ? c.send(new TlListTags({ ResourceArn: t.Arn })) : Promise.resolve(undefined) }, errors);
      return basicPage(
        id,
        name,
        'Custom terminology',
        [tab('Details', { sections: [section('Terminology', [['Description', t?.Description], ['Source language', t?.SourceLanguageCode], ['Target languages', t?.TargetLanguageCodes], ['Terms', t?.TermCount], ['Skipped terms', t?.SkippedTermCount], ['Directionality', t?.Directionality], ['Format', t?.Format], ['Encryption', t?.EncryptionKey?.Id], ['Created', t?.CreatedAt], ['Updated', t?.LastUpdatedAt]])] })],
        { arn: t?.Arn, tags: tagList(tags?.Tags), errors },
      );
    }
    if (kind === 'pd') {
      const p = (await c.send(new GetParallelDataCommand({ Name: name }))).ParallelDataProperties;
      const { tags } = await settle({ tags: p?.Arn ? c.send(new TlListTags({ ResourceArn: p.Arn })) : Promise.resolve(undefined) }, errors);
      return basicPage(
        id,
        name,
        'Parallel data',
        [tab('Details', { sections: [section('Parallel data', [['Status', p?.Status], ['Message', p?.Message], ['Source language', p?.SourceLanguageCode], ['Target languages', p?.TargetLanguageCodes], ['Source', p?.ParallelDataConfig?.S3Uri], ['Records (imported / failed / skipped)', `${p?.ImportedRecordCount ?? 0} / ${p?.FailedRecordCount ?? 0} / ${p?.SkippedRecordCount ?? 0}`], ['Created', p?.CreatedAt], ['Updated', p?.LastUpdatedAt]])] })],
        { status: p?.Status, arn: p?.Arn, tags: tagList(tags?.Tags), errors },
      );
    }
    throw httpError(`Unknown Translate page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || id === 'jobs:') throw httpError('This page has no tags', 400);
    await tl(profile, region).send(new TlTag({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || id === 'jobs:') throw httpError('This page has no tags', 400);
    await tl(profile, region).send(new TlUntag({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id !== 'jobs:',
};
