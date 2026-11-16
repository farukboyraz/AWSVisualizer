import {
  ForecastClient,
  ListDatasetGroupsCommand as FcListDatasetGroups,
  DescribeDatasetGroupCommand as FcDescribeDatasetGroup,
  ListPredictorsCommand,
  ListForecastsCommand,
  ListTagsForResourceCommand as FcListTags,
  TagResourceCommand as FcTag,
  UntagResourceCommand as FcUntag,
} from '@aws-sdk/client-forecast';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** Forecast. */
const fc = (p: string, r: string) => new ForecastClient(clientConfig(p, r));

export const forecastAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const groups = await pageAll((NextToken) => fc(profile, region).send(new FcListDatasetGroups({ NextToken })), (r) => r.DatasetGroups, (r) => r.NextToken);
    return groups.map((g) => ({ id: `dg:${g.DatasetGroupArn}`, name: g.DatasetGroupName || '', info: `Updated ${g.LastModificationTime?.toISOString().slice(0, 10) ?? '-'}` })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, arn] = splitId(id);
    if (kind !== 'dg') throw httpError(`Unknown Forecast page: ${id}`, 400);
    const c = fc(profile, region);
    const g = await c.send(new FcDescribeDatasetGroup({ DatasetGroupArn: arn }));
    const filter = [{ Key: 'DatasetGroupArn', Value: arn, Condition: 'IS' as const }];
    const errors: string[] = [];
    const parts = await settle(
      {
        predictors: pageAll((NextToken) => c.send(new ListPredictorsCommand({ NextToken, Filters: filter })), (r) => r.Predictors, (r) => r.NextToken),
        forecasts: pageAll((NextToken) => c.send(new ListForecastsCommand({ NextToken, Filters: filter })), (r) => r.Forecasts, (r) => r.NextToken),
        tags: c.send(new FcListTags({ ResourceArn: arn })),
      },
      errors,
    );
    return {
      id,
      title: g.DatasetGroupName || arn,
      subtitle: `${g.Domain ?? ''} dataset group`,
      status: g.Status,
      arn,
      tabs: [
        tab('Details', {
          sections: [section('Dataset group', [['Domain', g.Domain], ['Status', g.Status], ['Datasets', (g.DatasetArns || []).map(lastPart)], ['Created', g.CreationTime], ['Updated', g.LastModificationTime]], { note: 'Amazon Forecast is closed to new customers (July 2024).' })],
        }),
        tab('Predictors & forecasts', {
          tables: [
            table(['Predictor', 'Status', 'AutoPredictor', 'Created', 'Message'], (parts.predictors || []).map((p) => [p.PredictorName, p.Status, p.IsAutoPredictor, p.CreationTime, p.Message]), { title: 'Predictors', statusColumn: 1, emptyMessage: 'No predictors' }),
            table(['Forecast', 'Status', 'Predictor', 'Created', 'Message'], (parts.forecasts || []).map((f) => [f.ForecastName, f.Status, lastPart(f.PredictorArn), f.CreationTime, f.Message]), { title: 'Forecasts', statusColumn: 1, emptyMessage: 'No forecasts' }),
          ],
        }),
      ],
      tags: tagList(parts.tags?.Tags),
      actions: [],
      errors,
    };
  },
  async addTag(profile, region, id, _arn, key, value) {
    await fc(profile, region).send(new FcTag({ ResourceArn: splitId(id)[1], Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await fc(profile, region).send(new FcUntag({ ResourceArn: splitId(id)[1], TagKeys: [key] }));
  },
};
