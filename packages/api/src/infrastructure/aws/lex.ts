import {
  LexModelsV2Client,
  ListBotsCommand,
  DescribeBotCommand,
  ListBotAliasesCommand,
  ListBotVersionsCommand,
  ListBotLocalesCommand,
  ListTagsForResourceCommand as LexListTags,
  TagResourceCommand as LexTag,
  UntagResourceCommand as LexUntag,
} from '@aws-sdk/client-lex-models-v2';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagMap, accountId, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Lex (V2). */
const lex = (p: string, r: string) => new LexModelsV2Client(clientConfig(p, r));
const botArn = async (p: string, r: string, botId: string) => `arn:aws:lex:${r}:${await accountId(p, r)}:bot/${botId}`;

export const lexAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const bots = await pageAll((nextToken) => lex(profile, region).send(new ListBotsCommand({ nextToken })), (r) => r.botSummaries, (r) => r.nextToken);
    return bots.map((b) => ({ id: `bot:${b.botId}`, name: b.botName || b.botId || '', status: b.botStatus, info: [b.botType, b.latestBotVersion && `latest v${b.latestBotVersion}`].filter(Boolean).join(' · ') })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, botId] = splitId(id);
    if (kind !== 'bot') throw httpError(`Unknown Lex page: ${id}`, 400);
    const c = lex(profile, region);
    const b = await c.send(new DescribeBotCommand({ botId }));
    const arn = await botArn(profile, region, botId);
    const errors: string[] = [];
    const parts = await settle(
      {
        aliases: pageAll((nextToken) => c.send(new ListBotAliasesCommand({ botId, nextToken })), (r) => r.botAliasSummaries, (r) => r.nextToken),
        versions: pageAll((nextToken) => c.send(new ListBotVersionsCommand({ botId, nextToken })), (r) => r.botVersionSummaries, (r) => r.nextToken),
        locales: pageAll((nextToken) => c.send(new ListBotLocalesCommand({ botId, botVersion: 'DRAFT', nextToken })), (r) => r.botLocaleSummaries, (r) => r.nextToken),
        tags: c.send(new LexListTags({ resourceARN: arn })),
      },
      errors,
    );
    return {
      id,
      title: b.botName || botId,
      subtitle: `Lex V2 ${b.botType === 'BotNetwork' ? 'bot network' : 'bot'}`,
      status: b.botStatus,
      arn,
      tabs: [
        tab('Details', {
          sections: [
            section('Bot', [
              ['Bot ID', b.botId],
              ['Status', b.botStatus],
              ['Failure', b.failureReasons],
              ['Description', b.description],
              ['Type', b.botType],
              ['Members', (b.botMembers || []).map((m) => `${m.botMemberName} v${m.botMemberVersion}`)],
              ['Child-directed (COPPA)', b.dataPrivacy?.childDirected],
              ['Idle session timeout (s)', b.idleSessionTTLInSeconds],
              ['Role', b.roleArn],
              ['Created', b.creationDateTime],
              ['Updated', b.lastUpdatedDateTime],
            ]),
          ],
          tables: [table(['Locale', 'Status', 'Last build', 'Description'], (parts.locales || []).map((l) => [`${l.localeName} (${l.localeId})`, l.botLocaleStatus, l.lastBuildSubmittedDateTime, l.description]), { title: 'Languages (draft)', statusColumn: 1, emptyMessage: 'No languages' })],
        }),
        tab('Aliases & versions', {
          tables: [
            table(['Alias', 'Version', 'Status', 'Updated'], (parts.aliases || []).map((a) => [a.botAliasName, a.botVersion, a.botAliasStatus, a.lastUpdatedDateTime]), { title: 'Aliases', statusColumn: 2, emptyMessage: 'No aliases' }),
            table(['Version', 'Status', 'Created', 'Description'], (parts.versions || []).map((v) => [v.botVersion, v.botStatus, v.creationDateTime, v.description]), { title: 'Versions', statusColumn: 1, emptyMessage: 'No versions' }),
          ],
        }),
      ],
      tags: tagMap(parts.tags?.tags),
      actions: [],
      errors,
    };
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await lex(profile, region).send(new LexTag({ resourceARN: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await lex(profile, region).send(new LexUntag({ resourceARN: arn, tagKeys: [key] }));
  },
};
