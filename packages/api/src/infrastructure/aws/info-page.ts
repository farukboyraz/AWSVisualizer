import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, tab, httpError } from './page-common.js';
import type { PageServiceAdapter } from './page-adapter.js';

/**
 * Services the app can't list with an AWS profile get one information page
 * instead of a "coming soon" screen: services without a public API
 * (CloudShell, Q Developer…) and services AWS has shut down (`discontinued`
 * set - the date comes from the AWS General Reference "Services in Full
 * Shutdown" list). No SDK packages, no AWS calls, no dashboard count. Each
 * service has its own file that calls `infoPageAdapter`.
 */
export interface InfoService {
  title: string;
  subtitle: string;
  /** What the service is / was. */
  about: string;
  /** Why the app shows no resources. */
  why: string;
  /** Console (or replacement console) link for a region. */
  console: (region: string) => string;
  extra?: [string, string][];
  /** End-of-support date, e.g. "13 November 2025" - marks the page DISCONTINUED. */
  discontinued?: string;
  /** What AWS recommends instead (discontinued services). */
  replacement?: string;
}

export function infoPageAdapter(info: InfoService): PageServiceAdapter {
  const status = info.discontinued ? 'DISCONTINUED' : undefined;
  return {
    async list(): Promise<PageSummary[]> {
      return [{ id: 'info:', name: info.title, status, info: info.discontinued ? `Shut down on ${info.discontinued}` : info.subtitle }];
    },
    async detail(_profile, region, pageId): Promise<ResourcePage> {
      if (pageId !== 'info:') throw httpError(`Unknown ${info.title} page: ${pageId}`, 400);
      return {
        id: pageId,
        title: info.title,
        subtitle: info.discontinued ? 'Discontinued' : info.subtitle,
        status,
        tabs: [
          tab('About', {
            sections: [
              ...(info.discontinued ? [section('Status', [['End of support', info.discontinued], ['Recommended instead', info.replacement]], { note: 'AWS has removed this service; its console, API and resources are no longer available.' })] : []),
              section(info.discontinued ? 'What it was' : 'What it is', [['Service', info.about], ...(info.extra || [])]),
              section('In AWS Visualizer', [['Why no list', info.why]]),
              { title: 'Open', settings: [], copyable: [{ label: info.discontinued ? 'Replacement console' : 'Console', value: info.console(region || 'us-east-1') }] },
            ],
          }),
        ],
        actions: [],
        errors: [],
      };
    },
    uncounted: true,
  };
}
