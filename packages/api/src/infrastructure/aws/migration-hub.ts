import { MigrationHubClient, ListProgressUpdateStreamsCommand, ListMigrationTasksCommand } from '@aws-sdk/client-migration-hub';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const errName = (err: unknown) => (err as { name?: string })?.name || '';
/** Home-region services (Migration Hub, Discovery) and not-initialized services answer with these outside their setup. */
const notSetUp = (err: unknown) =>
  ['HomeRegionNotSetException', 'AccessDeniedException', 'UninitializedAccountException', 'InvalidInputException', 'AuthorizationErrorException'].includes(errName(err)) ||
  /home region|not (been )?initialized|not subscribed/i.test((err as { message?: string })?.message || '');
const quiet = <T>(p: Promise<T[]>) => p.catch((err) => (notSetUp(err) ? ([] as T[]) : Promise.reject(err)));

/** Migration Hub. */
const mh = (p: string, r: string) => new MigrationHubClient(clientConfig(p, r));

export const migrationHubAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const streams = await quiet(pageAll((NextToken) => mh(profile, region).send(new ListProgressUpdateStreamsCommand({ NextToken })), (r) => r.ProgressUpdateStreamSummaryList, (r) => r.NextToken));
    return streams.map((s) => ({ id: `stream:${s.ProgressUpdateStreamName}`, name: s.ProgressUpdateStreamName || '', info: 'Progress update stream' })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, stream] = splitId(id);
    if (kind !== 'stream') throw httpError(`Unknown Migration Hub page: ${id}`, 400);
    const tasks = await pageAll((NextToken) => mh(profile, region).send(new ListMigrationTasksCommand({ NextToken })), (r) => r.MigrationTaskSummaryList, (r) => r.NextToken);
    const mine = tasks.filter((t) => t.ProgressUpdateStream === stream);
    return {
      id,
      title: stream,
      subtitle: 'Progress update stream',
      tabs: [
        tab('Migration tasks', {
          sections: [section('Stream', [['Tasks', mine.length], ['Completed', mine.filter((t) => t.Status === 'COMPLETED').length], ['Failed', mine.filter((t) => t.Status === 'FAILED').length]], { note: 'Migration Hub only answers in its home region.' })],
          tables: [table(['Task', 'Status', 'Progress', 'Detail', 'Updated'], mine.map((t) => [t.MigrationTaskName, t.Status, t.ProgressPercent !== undefined ? `${t.ProgressPercent}%` : undefined, t.StatusDetail, t.UpdateDateTime]), { statusColumn: 1, emptyMessage: 'No tasks' })],
        }),
      ],
      actions: [],
      errors: [],
    };
  },
};
