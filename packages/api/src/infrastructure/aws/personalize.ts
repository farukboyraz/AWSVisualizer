import {
  PersonalizeClient,
  ListDatasetGroupsCommand as PzListDatasetGroups,
  DescribeDatasetGroupCommand as PzDescribeDatasetGroup,
  ListDatasetsCommand as PzListDatasets,
  ListSolutionsCommand,
  ListCampaignsCommand,
  ListRecommendersCommand,
  ListTagsForResourceCommand as PzListTags,
  TagResourceCommand as PzTag,
  UntagResourceCommand as PzUntag,
} from '@aws-sdk/client-personalize';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, lastPart, mapLimited, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Personalize. */
const pz = (p: string, r: string) => new PersonalizeClient(clientConfig(p, r));

export const personalizeAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const groups = await pageAll((nextToken) => pz(profile, region).send(new PzListDatasetGroups({ nextToken })), (r) => r.datasetGroups, (r) => r.nextToken);
    return groups.map((g) => ({ id: `dg:${g.datasetGroupArn}`, name: g.name || '', status: g.status, info: g.domain ? `Domain: ${g.domain}` : 'Custom' })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, arn] = splitId(id);
    if (kind !== 'dg') throw httpError(`Unknown Personalize page: ${id}`, 400);
    const c = pz(profile, region);
    const g = (await c.send(new PzDescribeDatasetGroup({ datasetGroupArn: arn }))).datasetGroup;
    if (!g) throw httpError(`Dataset group not found: ${arn}`, 404);
    const errors: string[] = [];
    const parts = await settle(
      {
        datasets: pageAll((nextToken) => c.send(new PzListDatasets({ datasetGroupArn: arn, nextToken })), (r) => r.datasets, (r) => r.nextToken),
        solutions: pageAll((nextToken) => c.send(new ListSolutionsCommand({ datasetGroupArn: arn, nextToken })), (r) => r.solutions, (r) => r.nextToken),
        recommenders: pageAll((nextToken) => c.send(new ListRecommendersCommand({ datasetGroupArn: arn, nextToken })), (r) => r.recommenders, (r) => r.nextToken),
        tags: c.send(new PzListTags({ resourceArn: arn })),
      },
      errors,
    );
    const campaigns = (await mapLimited(parts.solutions || [], 4, (s) => pageAll((nextToken) => c.send(new ListCampaignsCommand({ solutionArn: s.solutionArn, nextToken })), (r) => r.campaigns, (r) => r.nextToken).catch(() => []))).flat();
    return {
      id,
      title: g.name || arn,
      subtitle: g.domain ? `${g.domain} dataset group` : 'Custom dataset group',
      status: g.status,
      arn,
      tabs: [
        tab('Details', {
          sections: [section('Dataset group', [['Status', g.status], ['Failure', g.failureReason], ['Domain', g.domain ?? 'Custom'], ['Role', g.roleArn], ['KMS key', g.kmsKeyArn], ['Created', g.creationDateTime], ['Updated', g.lastUpdatedDateTime]])],
          tables: [table(['Dataset', 'Type', 'Status', 'Updated'], (parts.datasets || []).map((d) => [d.name, d.datasetType, d.status, d.lastUpdatedDateTime]), { title: 'Datasets', statusColumn: 2, emptyMessage: 'No datasets' })],
        }),
        tab('Solutions & campaigns', {
          tables: [
            table(['Solution', 'Recipe', 'Status', 'Updated'], (parts.solutions || []).map((s) => [s.name, lastPart(s.recipeArn), s.status, s.lastUpdatedDateTime]), { title: 'Solutions', statusColumn: 2, emptyMessage: 'No solutions' }),
            table(['Campaign', 'Status', 'Updated', 'Failure'], campaigns.map((x) => [x.name, x.status, x.lastUpdatedDateTime, x.failureReason]), { title: 'Campaigns', statusColumn: 1, emptyMessage: 'No campaigns' }),
            table(['Recommender', 'Recipe', 'Status', 'Updated'], (parts.recommenders || []).map((r) => [r.name, lastPart(r.recipeArn), r.status, r.lastUpdatedDateTime]), { title: 'Recommenders (domain groups)', statusColumn: 2, emptyMessage: 'No recommenders' }),
          ],
        }),
      ],
      tags: (parts.tags?.tags || []).map((t) => ({ key: t.tagKey || '', value: t.tagValue || '' })),
      actions: [],
      errors,
    };
  },
  async addTag(profile, region, id, _arn, key, value) {
    await pz(profile, region).send(new PzTag({ resourceArn: splitId(id)[1], tags: [{ tagKey: key, tagValue: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await pz(profile, region).send(new PzUntag({ resourceArn: splitId(id)[1], tagKeys: [key] }));
  },
};
