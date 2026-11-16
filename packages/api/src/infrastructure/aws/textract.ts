import { TextractClient, ListAdaptersCommand, GetAdapterCommand, ListAdapterVersionsCommand } from '@aws-sdk/client-textract';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, clientConfig, byName, basicPage } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Textract. */
const tx = (p: string, r: string) => new TextractClient(clientConfig(p, r));

export const textractAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const adapters = await pageAll((NextToken) => tx(profile, region).send(new ListAdaptersCommand({ NextToken })), (r) => r.Adapters, (r) => r.NextToken);
    return [
      { id: 'info:', name: 'About Textract', group: 'Service', info: 'Text, forms, tables and queries from documents' },
      ...adapters.map((a) => ({ id: `ad:${a.AdapterId}`, name: a.AdapterName || a.AdapterId || '', group: 'Custom adapters', info: (a.FeatureTypes || []).join(', ') })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const [kind, rest] = splitId(id);
    if (kind === 'info') {
      return basicPage(id, 'Textract', 'Document analysis', [
        tab('About', {
          sections: [
            section('Service', [
              ['What it does', 'Extracts printed and handwritten text, forms (key-value pairs), tables, signatures and answers to queries from PDFs and images.'],
              ['Resources', 'Textract keeps no documents - every analysis is a request. Only custom adapters (fine-tuning for queries) are stored resources.'],
              ['APIs', 'DetectDocumentText, AnalyzeDocument, AnalyzeExpense, AnalyzeID, StartDocumentAnalysis (async)'],
            ]),
          ],
        }),
      ]);
    }
    if (kind !== 'ad') throw httpError(`Unknown Textract page: ${id}`, 400);
    const c = tx(profile, region);
    const a = await c.send(new GetAdapterCommand({ AdapterId: rest }));
    const errors: string[] = [];
    const { versions } = await settle({ versions: pageAll((NextToken) => c.send(new ListAdapterVersionsCommand({ AdapterId: rest, NextToken })), (r) => r.AdapterVersions, (r) => r.NextToken) }, errors);
    return basicPage(
      id,
      a.AdapterName || rest,
      'Textract adapter',
      [
        tab('Details', {
          sections: [section('Adapter', [['Adapter ID', a.AdapterId], ['Description', a.Description], ['Features', a.FeatureTypes], ['Auto update', a.AutoUpdate], ['Created', a.CreationTime]])],
          tables: [table(['Version', 'Status', 'Message', 'Created'], (versions || []).map((v) => [v.AdapterVersion, v.Status, v.StatusMessage, v.CreationTime]), { title: 'Versions', statusColumn: 1, emptyMessage: 'No versions' })],
        }),
      ],
      { tags: tagMap(a.Tags), errors },
    );
  },
  uncounted: true,
};
