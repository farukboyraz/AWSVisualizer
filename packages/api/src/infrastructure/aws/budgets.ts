import {
  BudgetsClient,
  DescribeBudgetsCommand,
  DescribeBudgetCommand,
  DescribeNotificationsForBudgetCommand,
  DescribeSubscribersForNotificationCommand,
  DescribeBudgetPerformanceHistoryCommand,
  DescribeBudgetActionsForBudgetCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Budget,
  type Spend,
} from '@aws-sdk/client-budgets';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, accountId, mapLimited } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Budgets is global; its endpoint lives in us-east-1. */
const client = (p: string) => new BudgetsClient({ region: 'us-east-1', credentials: cachedCredentials(p) });

const spend = (s?: Spend) => (s?.Amount ? `${s.Unit === 'USD' ? '$' : ''}${Number(s.Amount).toFixed(2)}${s.Unit === 'USD' ? '' : ` ${s.Unit}`}` : undefined);
const pct = (a?: Spend, b?: Spend) => (a?.Amount && b?.Amount && Number(b.Amount) ? Math.round((Number(a.Amount) / Number(b.Amount)) * 100) : undefined);

/** OK / FORECASTED_OVER / OVER, as the console's health column. */
function health(b: Budget) {
  const actual = pct(b.CalculatedSpend?.ActualSpend, b.BudgetLimit);
  const forecast = pct(b.CalculatedSpend?.ForecastedSpend, b.BudgetLimit);
  if (actual === undefined) return undefined;
  if (actual >= 100) return 'EXCEEDED';
  if ((forecast ?? 0) >= 100) return 'FORECAST_EXCEEDED';
  return 'OK';
}

const budgetArn = (acct: string, name: string) => `arn:aws:budgets::${acct}:budget/${name}`;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const AccountId = await accountId(profile, region);
  const c = client(profile);
  const budgets = await pageAll((NextToken) => c.send(new DescribeBudgetsCommand({ AccountId, NextToken })), (r) => r.Budgets, (r) => r.NextToken);
  return budgets
    .map((b) => ({
      id: `b:${b.BudgetName}`,
      name: b.BudgetName || '',
      group: `${b.BudgetType?.replace(/_/g, ' ').toLowerCase().replace(/^\w/, (x) => x.toUpperCase()) ?? ''} budgets`,
      status: health(b),
      info: [spend(b.CalculatedSpend?.ActualSpend) && `${spend(b.CalculatedSpend?.ActualSpend)} of ${spend(b.BudgetLimit) ?? '-'}`, b.TimeUnit?.toLowerCase(), spend(b.CalculatedSpend?.ForecastedSpend) && `forecast ${spend(b.CalculatedSpend?.ForecastedSpend)}`].filter(Boolean).join(' · '),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const [kind, name] = splitId(id);
  if (kind !== 'b') throw httpError(`Unknown budget page: ${id}`, 400);
  const AccountId = await accountId(profile, region);
  const c = client(profile);
  const b = (await c.send(new DescribeBudgetCommand({ AccountId, BudgetName: name }))).Budget;
  if (!b) throw httpError(`Budget not found: ${name}`, 404);
  const arn = budgetArn(AccountId, name);
  const errors: string[] = [];
  const parts = await settle(
    {
      notifications: pageAll((NextToken) => c.send(new DescribeNotificationsForBudgetCommand({ AccountId, BudgetName: name, NextToken })), (r) => r.Notifications, (r) => r.NextToken),
      history: c.send(new DescribeBudgetPerformanceHistoryCommand({ AccountId, BudgetName: name, MaxResults: 12 })),
      actions: pageAll((NextToken) => c.send(new DescribeBudgetActionsForBudgetCommand({ AccountId, BudgetName: name, NextToken })), (r) => r.Actions, (r) => r.NextToken),
      tags: c.send(new ListTagsForResourceCommand({ ResourceARN: arn })),
    },
    errors,
  );
  const notes = parts.notifications || [];
  const subscribers = await mapLimited(notes, 4, (Notification) =>
    pageAll((NextToken) => c.send(new DescribeSubscribersForNotificationCommand({ AccountId, BudgetName: name, Notification, NextToken })), (r) => r.Subscribers, (r) => r.NextToken).catch(() => []),
  );
  const filters = Object.entries(b.CostFilters || {});
  const ct = b.CostTypes;
  return {
    id,
    title: name,
    subtitle: `${b.BudgetType ?? ''} budget · ${b.TimeUnit?.toLowerCase() ?? ''}`,
    status: health(b),
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Budget', [
            ['Type', b.BudgetType],
            ['Period', b.TimeUnit],
            ['Budgeted amount', spend(b.BudgetLimit)],
            ['Actual', spend(b.CalculatedSpend?.ActualSpend)],
            ['Actual vs budget', pct(b.CalculatedSpend?.ActualSpend, b.BudgetLimit) !== undefined ? `${pct(b.CalculatedSpend?.ActualSpend, b.BudgetLimit)}%` : undefined],
            ['Forecasted', spend(b.CalculatedSpend?.ForecastedSpend)],
            ['Forecast vs budget', pct(b.CalculatedSpend?.ForecastedSpend, b.BudgetLimit) !== undefined ? `${pct(b.CalculatedSpend?.ForecastedSpend, b.BudgetLimit)}%` : undefined],
            ['Start', b.TimePeriod?.Start],
            ['End', b.TimePeriod?.End],
            ['Auto-adjust', b.AutoAdjustData?.AutoAdjustType],
            ['Planned amounts', b.PlannedBudgetLimits ? `${Object.keys(b.PlannedBudgetLimits).length} periods` : undefined],
            ['Updated', b.LastUpdatedTime],
          ]),
          ...(ct
            ? [
                section('Cost aggregation', [
                  ['Include tax', ct.IncludeTax],
                  ['Include support', ct.IncludeSupport],
                  ['Include credits', ct.IncludeCredit],
                  ['Include refunds', ct.IncludeRefund],
                  ['Include discounts', ct.IncludeDiscount],
                  ['Use amortized', ct.UseAmortized],
                  ['Use blended', ct.UseBlended],
                ]),
              ]
            : []),
        ],
        tables: [table(['Filter', 'Values'], filters.map(([k, v]) => [k, v]), { title: 'Filters', emptyMessage: 'No filters (all costs)' })],
      }),
      tab('Alerts', {
        tables: [
          table(
            ['Trigger', 'Threshold', 'State', 'Recipients'],
            notes.map((n, i) => [n.NotificationType, `${n.ComparisonOperator?.replace(/_/g, ' ').toLowerCase()} ${n.Threshold}${n.ThresholdType === 'PERCENTAGE' ? '%' : ''}`, n.NotificationState, subscribers[i].map((s) => `${s.SubscriptionType}: ${s.Address}`)]),
            { statusColumn: 2, emptyMessage: 'No alerts' },
          ),
        ],
      }),
      tab('History', {
        tables: [
          table(
            ['Period start', 'Budgeted', 'Actual', '% of budget'],
            (parts.history?.BudgetPerformanceHistory?.BudgetedAndActualAmountsList || [])
              .slice()
              .reverse()
              .map((h) => [h.TimePeriod?.Start, spend(h.BudgetedAmount), spend(h.ActualAmount), pct(h.ActualAmount, h.BudgetedAmount) !== undefined ? `${pct(h.ActualAmount, h.BudgetedAmount)}%` : '-']),
            { emptyMessage: 'No history yet' },
          ),
        ],
      }),
      tab('Actions', {
        tables: [
          table(
            ['Action', 'Type', 'Trigger', 'Threshold', 'Approval', 'Status'],
            (parts.actions || []).map((a) => [a.ActionId, a.ActionType, a.NotificationType, `${a.ActionThreshold?.ActionThresholdValue}${a.ActionThreshold?.ActionThresholdType === 'PERCENTAGE' ? '%' : ''}`, a.ApprovalModel, a.Status]),
            { statusColumn: 5, emptyMessage: 'No budget actions' },
          ),
        ],
      }),
    ],
    tags: tagList(parts.tags?.ResourceTags),
    actions: [],
    errors,
  };
}

async function arnFor(profile: string, region: string, id: string) {
  const [kind, name] = splitId(id);
  if (kind !== 'b') throw httpError(`Unknown budget: ${id}`, 400);
  return budgetArn(await accountId(profile, region), name);
}

export const budgetsAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile).send(new TagResourceCommand({ ResourceARN: await arnFor(profile, region, id), ResourceTags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    await client(profile).send(new UntagResourceCommand({ ResourceARN: await arnFor(profile, region, id), ResourceTagKeys: [key] }));
  },
};
