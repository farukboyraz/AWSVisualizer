import {
  TranscribeClient,
  ListTranscriptionJobsCommand,
  ListVocabulariesCommand,
  GetVocabularyCommand,
  ListVocabularyFiltersCommand,
  GetVocabularyFilterCommand,
  ListLanguageModelsCommand,
  DescribeLanguageModelCommand,
} from '@aws-sdk/client-transcribe';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, clientConfig, byName, basicPage } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Transcribe. */
const tr = (p: string, r: string) => new TranscribeClient(clientConfig(p, r));
const JOB_LIMIT = 100;

export const transcribeAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = tr(profile, region);
    const [vocabs, filters, models] = await Promise.all([
      pageAll((NextToken) => c.send(new ListVocabulariesCommand({ NextToken })), (r) => r.Vocabularies, (r) => r.NextToken),
      pageAll((NextToken) => c.send(new ListVocabularyFiltersCommand({ NextToken })), (r) => r.VocabularyFilters, (r) => r.NextToken).catch(() => []),
      pageAll((NextToken) => c.send(new ListLanguageModelsCommand({ NextToken })), (r) => r.Models, (r) => r.NextToken).catch(() => []),
    ]);
    return [
      { id: 'jobs:', name: 'Transcription jobs', group: 'Jobs', info: `Most recent ${JOB_LIMIT}` },
      ...vocabs.map((v) => ({ id: `vocab:${v.VocabularyName}`, name: v.VocabularyName || '', group: 'Custom vocabularies', status: v.VocabularyState, info: v.LanguageCode })).sort(byName),
      ...filters.map((f) => ({ id: `filter:${f.VocabularyFilterName}`, name: f.VocabularyFilterName || '', group: 'Vocabulary filters', info: f.LanguageCode })).sort(byName),
      ...models.map((m) => ({ id: `clm:${m.ModelName}`, name: m.ModelName || '', group: 'Custom language models', status: m.ModelStatus, info: [m.LanguageCode, m.BaseModelName].filter(Boolean).join(' · ') })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = tr(profile, region);
    const [kind, name] = splitId(id);
    if (kind === 'jobs') {
      const jobs = await pageAll((NextToken) => c.send(new ListTranscriptionJobsCommand({ NextToken, MaxResults: 100 })), (r) => r.TranscriptionJobSummaries, (r) => r.NextToken, JOB_LIMIT);
      return basicPage(id, 'Transcription jobs', `Most recent ${JOB_LIMIT}`, [
        tab('Jobs', {
          tables: [
            table(
              ['Job', 'Status', 'Language', 'Created', 'Completed', 'Redaction', 'Failure'],
              jobs.slice(0, JOB_LIMIT).sort((a, b) => (b.CreationTime?.getTime() ?? 0) - (a.CreationTime?.getTime() ?? 0)).map((j) => [j.TranscriptionJobName, j.TranscriptionJobStatus, j.LanguageCode ?? (j.IdentifyLanguage ? 'auto' : undefined), j.CreationTime, j.CompletionTime, j.ContentRedaction?.RedactionType, j.FailureReason]),
              { statusColumn: 1, emptyMessage: 'No transcription jobs (jobs are kept for 90 days)' },
            ),
          ],
        }),
      ]);
    }
    if (kind === 'vocab') {
      // DownloadUri is a short-lived presigned link - not shown.
      const v = await c.send(new GetVocabularyCommand({ VocabularyName: name }));
      return basicPage(id, name, 'Custom vocabulary', [tab('Details', { sections: [section('Vocabulary', [['State', v.VocabularyState], ['Language', v.LanguageCode], ['Failure', v.FailureReason], ['Modified', v.LastModifiedTime]])] })], { status: v.VocabularyState });
    }
    if (kind === 'filter') {
      const f = await c.send(new GetVocabularyFilterCommand({ VocabularyFilterName: name }));
      return basicPage(id, name, 'Vocabulary filter', [tab('Details', { sections: [section('Filter', [['Language', f.LanguageCode], ['Modified', f.LastModifiedTime]])] })]);
    }
    if (kind === 'clm') {
      const m = (await c.send(new DescribeLanguageModelCommand({ ModelName: name }))).LanguageModel;
      return basicPage(
        id,
        name,
        'Custom language model',
        [tab('Details', { sections: [section('Model', [['Status', m?.ModelStatus], ['Language', m?.LanguageCode], ['Base model', m?.BaseModelName], ['Upgrade available', m?.UpgradeAvailability], ['Training data', m?.InputDataConfig?.S3Uri], ['Tuning data', m?.InputDataConfig?.TuningDataS3Uri], ['Role', m?.InputDataConfig?.DataAccessRoleArn], ['Failure', m?.FailureReason], ['Created', m?.CreateTime], ['Modified', m?.LastModifiedTime]])] })],
        { status: m?.ModelStatus },
      );
    }
    throw httpError(`Unknown Transcribe page: ${id}`, 400);
  },
  countable: (row) => row.id !== 'jobs:',
};
