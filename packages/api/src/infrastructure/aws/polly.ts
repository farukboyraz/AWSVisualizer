import { PollyClient, DescribeVoicesCommand, ListLexiconsCommand, GetLexiconCommand } from '@aws-sdk/client-polly';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, clientConfig, byName, basicPage } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Polly. */
const po = (p: string, r: string) => new PollyClient(clientConfig(p, r));

export const pollyAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const lexicons = (await po(profile, region).send(new ListLexiconsCommand({}))).Lexicons || [];
    return [
      { id: 'voices:', name: 'Voices', group: 'Service', info: 'Every voice and the engines it supports' },
      ...lexicons.map((l) => ({ id: `lex:${l.Name}`, name: l.Name || '', group: 'Pronunciation lexicons', info: `${l.Attributes?.LanguageCode ?? ''} · ${l.Attributes?.LexemesCount ?? 0} lexemes` })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = po(profile, region);
    const [kind, rest] = splitId(id);
    if (kind === 'voices') {
      const voices = await pageAll((NextToken) => c.send(new DescribeVoicesCommand({ NextToken })), (r) => r.Voices, (r) => r.NextToken);
      return basicPage(id, 'Voices', `${voices.length} voices`, [
        tab('Voices', {
          tables: [table(['Voice', 'Language', 'Gender', 'Engines', 'Also speaks'], voices.sort((a, b) => (a.LanguageName || '').localeCompare(b.LanguageName || '') || (a.Name || '').localeCompare(b.Name || '')).map((v) => [v.Name, `${v.LanguageName} (${v.LanguageCode})`, v.Gender, v.SupportedEngines, v.AdditionalLanguageCodes]), { emptyMessage: 'No voices' })],
        }),
      ]);
    }
    if (kind !== 'lex') throw httpError(`Unknown Polly page: ${id}`, 400);
    const l = await c.send(new GetLexiconCommand({ Name: rest }));
    const at = l.LexiconAttributes;
    const tabs: PageTab[] = [tab('Details', { sections: [section('Lexicon', [['Language', at?.LanguageCode], ['Alphabet', at?.Alphabet], ['Lexemes', at?.LexemesCount], ['Size (bytes)', at?.Size], ['Modified', at?.LastModified]])] })];
    if (l.Lexicon?.Content) tabs.push(tab('Content (PLS)', { text: l.Lexicon.Content }));
    return basicPage(id, rest, 'Pronunciation lexicon', tabs, { arn: at?.LexiconArn });
  },
  uncounted: true,
};
