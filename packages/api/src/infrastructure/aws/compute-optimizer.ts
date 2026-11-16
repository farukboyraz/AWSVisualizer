import {
  ComputeOptimizerClient,
  GetEnrollmentStatusCommand,
  GetRecommendationSummariesCommand,
  GetEC2InstanceRecommendationsCommand,
  GetAutoScalingGroupRecommendationsCommand,
  GetEBSVolumeRecommendationsCommand,
  GetLambdaFunctionRecommendationsCommand,
  GetECSServiceRecommendationsCommand,
  type SavingsOpportunity,
  type RecommendationSummary,
} from '@aws-sdk/client-compute-optimizer';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary, PageTable } from '../../domain/entities/index.js';
import { section, table, tab, httpError, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ComputeOptimizerClient({ region: r, credentials: cachedCredentials(p) });

const LIMIT = 500;

/** Pages Compute Optimizer's nextToken calls (each takes maxResults ≤ 1000). */
async function pageCo<R extends { nextToken?: string }, T>(call: (nextToken?: string) => Promise<R>, pick: (r: R) => T[] | undefined): Promise<T[]> {
  const out: T[] = [];
  let token: string | undefined;
  do {
    const r = await call(token);
    out.push(...(pick(r) || []));
    token = r.nextToken;
  } while (token && out.length < LIMIT);
  return out.slice(0, LIMIT);
}

const money = (s?: SavingsOpportunity) => (s?.estimatedMonthlySavings?.value ? `$${s.estimatedMonthlySavings.value.toFixed(2)}/mo (${(s.savingsOpportunityPercentage ?? 0).toFixed(0)}%)` : undefined);

/** Non-optimized first, then biggest savings. */
const FINDING_ORDER: Record<string, number> = { OVER_PROVISIONED: 0, Overprovisioned: 0, UNDER_PROVISIONED: 1, Underprovisioned: 1, NOT_OPTIMIZED: 1, NotOptimized: 1, OPTIMIZED: 2, Optimized: 2 };
const byFinding = (a: { finding?: string }, b: { finding?: string }) => (FINDING_ORDER[a.finding || ''] ?? 3) - (FINDING_ORDER[b.finding || ''] ?? 3);

interface Category {
  label: string;
  summaryType: string;
  rows(c: ComputeOptimizerClient): Promise<PageTable>;
}

const CATEGORIES: Record<string, Category> = {
  ec2: {
    label: 'EC2 instances',
    summaryType: 'Ec2Instance',
    async rows(c) {
      const recs = (await pageCo((nextToken) => c.send(new GetEC2InstanceRecommendationsCommand({ nextToken })), (r) => r.instanceRecommendations)).sort(byFinding);
      return table(
        ['Instance', 'Finding', 'Current type', 'Recommended', 'Savings', 'Risk', 'Reasons'],
        recs.map((r) => {
          const top = r.recommendationOptions?.find((o) => o.rank === 1);
          return [r.instanceName || lastPart(r.instanceArn), r.finding, r.currentInstanceType, top?.instanceType, money(top?.savingsOpportunity), r.currentPerformanceRisk, r.findingReasonCodes];
        }),
        { statusColumn: 1, emptyMessage: 'No EC2 recommendations yet (needs ~30 hours of metrics)' },
      );
    },
  },
  asg: {
    label: 'Auto Scaling groups',
    summaryType: 'AutoScalingGroup',
    async rows(c) {
      const recs = (await pageCo((nextToken) => c.send(new GetAutoScalingGroupRecommendationsCommand({ nextToken })), (r) => r.autoScalingGroupRecommendations)).sort(byFinding);
      return table(
        ['Group', 'Finding', 'Current type', 'Recommended', 'Savings', 'Risk'],
        recs.map((r) => {
          const top = r.recommendationOptions?.find((o) => o.rank === 1);
          return [r.autoScalingGroupName, r.finding, r.currentConfiguration?.instanceType, top?.configuration?.instanceType, money(top?.savingsOpportunity), r.currentPerformanceRisk];
        }),
        { statusColumn: 1, emptyMessage: 'No Auto Scaling group recommendations' },
      );
    },
  },
  ebs: {
    label: 'EBS volumes',
    summaryType: 'EbsVolume',
    async rows(c) {
      const recs = (await pageCo((nextToken) => c.send(new GetEBSVolumeRecommendationsCommand({ nextToken })), (r) => r.volumeRecommendations)).sort(byFinding);
      const vol = (v?: { volumeType?: string; volumeSize?: number; volumeBaselineIOPS?: number }) => (v ? `${v.volumeType} ${v.volumeSize} GiB · ${v.volumeBaselineIOPS ?? '-'} IOPS` : undefined);
      return table(
        ['Volume', 'Finding', 'Current', 'Recommended', 'Savings', 'Risk'],
        recs.map((r) => {
          const top = r.volumeRecommendationOptions?.find((o) => o.rank === 1);
          return [lastPart(r.volumeArn), r.finding, vol(r.currentConfiguration), vol(top?.configuration), money(top?.savingsOpportunity), r.currentPerformanceRisk];
        }),
        { statusColumn: 1, emptyMessage: 'No EBS recommendations' },
      );
    },
  },
  lambda: {
    label: 'Lambda functions',
    summaryType: 'LambdaFunction',
    async rows(c) {
      const recs = (await pageCo((nextToken) => c.send(new GetLambdaFunctionRecommendationsCommand({ nextToken })), (r) => r.lambdaFunctionRecommendations)).sort(byFinding);
      return table(
        ['Function', 'Finding', 'Current memory', 'Recommended', 'Savings', 'Invocations', 'Reasons'],
        recs.map((r) => {
          const top = r.memorySizeRecommendationOptions?.find((o) => o.rank === 1);
          return [lastPart(r.functionArn?.replace(/:\$LATEST$|:\d+$/, '')), r.finding, r.currentMemorySize && `${r.currentMemorySize} MB`, top?.memorySize && `${top.memorySize} MB`, money(top?.savingsOpportunity), r.numberOfInvocations, r.findingReasonCodes];
        }),
        { statusColumn: 1, emptyMessage: 'No Lambda recommendations' },
      );
    },
  },
  ecs: {
    label: 'ECS services (Fargate)',
    summaryType: 'EcsService',
    async rows(c) {
      const recs = (await pageCo((nextToken) => c.send(new GetECSServiceRecommendationsCommand({ nextToken })), (r) => r.ecsServiceRecommendations)).sort(byFinding);
      const size = (cpu?: number, mem?: number) => (cpu || mem ? `${cpu ?? '-'} CPU · ${mem ?? '-'} MB` : undefined);
      return table(
        ['Service', 'Finding', 'Current', 'Recommended', 'Savings', 'Reasons'],
        recs.map((r) => {
          const top = r.serviceRecommendationOptions?.[0];
          return [lastPart(r.serviceArn), r.finding, size(r.currentServiceConfiguration?.cpu, r.currentServiceConfiguration?.memory), size(top?.cpu, top?.memory), money(top?.savingsOpportunity), r.findingReasonCodes];
        }),
        { statusColumn: 1, emptyMessage: 'No ECS recommendations' },
      );
    },
  },
};

const summaryInfo = (s?: RecommendationSummary) => {
  if (!s) return 'No data yet';
  const counts = (s.summaries || []).filter((x) => x.value).map((x) => `${x.value} ${String(x.name).toLowerCase().replace(/_/g, '-')}`);
  return [counts.join(' · ') || 'No resources', money(s.savingsOpportunity) && `save ${money(s.savingsOpportunity)}`].filter(Boolean).join(' · ');
};

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const e = await c.send(new GetEnrollmentStatusCommand({}));
  const rows: PageSummary[] = [{ id: 'enroll:', name: 'Account enrollment', group: 'Account', status: e.status, info: e.statusReason || (e.memberAccountsEnrolled ? 'Member accounts enrolled' : 'This account') }];
  if (e.status !== 'Active') return rows;
  const summaries = await pageCo((nextToken) => c.send(new GetRecommendationSummariesCommand({ nextToken })), (r) => r.recommendationSummaries).catch((): RecommendationSummary[] => []);
  for (const [key, cat] of Object.entries(CATEGORIES)) {
    rows.push({ id: `${key}:`, name: cat.label, group: 'Recommendations', info: summaryInfo(summaries.find((s) => s.recommendationResourceType === cat.summaryType)) });
  }
  return rows;
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind] = splitId(id);
  if (kind === 'enroll') {
    const e = await c.send(new GetEnrollmentStatusCommand({}));
    return {
      id,
      title: 'Compute Optimizer',
      subtitle: 'Account enrollment',
      status: e.status,
      tabs: [
        tab('Enrollment', {
          sections: [
            section('Status', [['Status', e.status], ['Reason', e.statusReason], ['Member accounts enrolled', e.memberAccountsEnrolled], ['Member accounts opted in', e.numberOfMemberAccountsOptedIn], ['Updated', e.lastUpdatedTimestamp]], {
              note: e.status === 'Active' ? undefined : 'Opt in from the Compute Optimizer console to get recommendations.',
            }),
          ],
        }),
      ],
      actions: [],
      errors: [],
    };
  }
  const cat = CATEGORIES[kind];
  if (!cat) throw httpError(`Unknown Compute Optimizer page: ${id}`, 400);
  const t = await cat.rows(c);
  return {
    id,
    title: cat.label,
    subtitle: `Compute Optimizer recommendations in ${region}`,
    tabs: [tab('Recommendations', { tables: [{ ...t, title: t.rows.length >= LIMIT ? `First ${LIMIT}` : undefined }] })],
    actions: [],
    errors: [],
  };
}

export const computeOptimizerAdapter: PageServiceAdapter = {
  list,
  detail,
  uncounted: true,
};
