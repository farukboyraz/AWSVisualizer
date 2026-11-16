import {
  DescribeAccountAuditConfigurationCommand,
  ListAuditTasksCommand,
  ListAuditFindingsCommand,
  ListSecurityProfilesCommand,
  DescribeSecurityProfileCommand,
  ListTargetsForSecurityProfileCommand,
  ListActiveViolationsCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-iot';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';
import { iot, iotTags } from './iot-core.js';


/** IoT Device Defender. */
export const deviceDefenderAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = iot(profile, region);
    const profiles = await pageAll((nextToken) => c.send(new ListSecurityProfilesCommand({ nextToken })), (r) => r.securityProfileIdentifiers, (r) => r.nextToken);
    return [
      { id: 'audit:', name: 'Audit', group: 'Audit', info: 'Configuration, recent audits and findings' },
      { id: 'violations:', name: 'Active violations', group: 'Detect', info: 'Devices breaking a security profile' },
      ...profiles.map((p) => ({ id: `sp:${p.name}`, name: p.name || '', group: 'Security profiles' })).sort(byName),
    ];
  },
  async detail(profile, region, id) {
    const c = iot(profile, region);
    const [kind, name] = splitId(id);
    const errors: string[] = [];
    if (kind === 'audit') {
      const now = new Date();
      const parts = await settle(
        {
          config: c.send(new DescribeAccountAuditConfigurationCommand({})),
          tasks: c.send(new ListAuditTasksCommand({ startTime: new Date(now.getTime() - 30 * 86_400_000), endTime: now, maxResults: 25 })),
        },
        errors,
      );
      const latest = (parts.tasks?.tasks || []).find((t) => t.taskStatus === 'COMPLETED');
      const findings = latest ? await pageAll((nextToken) => c.send(new ListAuditFindingsCommand({ taskId: latest.taskId, nextToken })), (r) => r.findings, (r) => r.nextToken, 200).catch(() => []) : [];
      const checks = Object.entries(parts.config?.auditCheckConfigurations || {});
      return {
        id,
        title: 'Audit',
        subtitle: 'Device Defender audit',
        tabs: [
          tab('Findings', {
            tables: [
              table(['Check', 'Severity', 'Resource', 'Reason', 'Suppressed'], findings.map((f) => [f.checkName, f.severity, f.nonCompliantResource?.resourceIdentifier ? Object.values(f.nonCompliantResource.resourceIdentifier).find(Boolean) : f.nonCompliantResource?.resourceType, f.reasonForNonCompliance, f.isSuppressed]), {
                title: latest ? `Latest completed audit (${latest.taskId?.slice(0, 8)})` : 'No completed audit in the last 30 days',
                emptyMessage: 'No findings',
              }),
            ],
          }),
          tab('Audits', {
            tables: [table(['Audit', 'Type', 'Status'], (parts.tasks?.tasks || []).map((t) => [t.taskId, t.taskType, t.taskStatus]), { title: 'Last 30 days', statusColumn: 2, emptyMessage: 'No audits' })],
          }),
          tab('Configuration', {
            sections: [section('Audit', [['Role', parts.config?.roleArn], ['Enabled checks', checks.filter(([, v]) => v.enabled).length], ['SNS notifications', parts.config?.auditNotificationTargetConfigurations?.SNS?.targetArn]])],
            tables: [table(['Check', 'Enabled'], checks.map(([k, v]) => [k, v.enabled]), { title: 'Checks', emptyMessage: 'Audit not configured' })],
          }),
        ],
        actions: [],
        errors,
      };
    }
    if (kind === 'violations') {
      const v = await pageAll((nextToken) => c.send(new ListActiveViolationsCommand({ nextToken })), (r) => r.activeViolations, (r) => r.nextToken, 500);
      return {
        id,
        title: 'Active violations',
        subtitle: 'Device Defender detect',
        tabs: [tab('Violations', { tables: [table(['Thing', 'Security profile', 'Behavior', 'Since', 'Verification'], v.map((x) => [x.thingName, x.securityProfileName, x.behavior?.name, x.violationStartTime, x.verificationState]), { emptyMessage: 'No active violations' })] })],
        actions: [],
        errors,
      };
    }
    if (kind === 'sp') {
      const s = await c.send(new DescribeSecurityProfileCommand({ securityProfileName: name }));
      const parts = await settle({ targets: pageAll((nextToken) => c.send(new ListTargetsForSecurityProfileCommand({ securityProfileName: name, nextToken })), (r) => r.securityProfileTargets, (r) => r.nextToken), tags: iotTags(c, s.securityProfileArn) }, errors);
      return {
        id,
        title: name,
        subtitle: 'Security profile',
        arn: s.securityProfileArn,
        tabs: [
          tab('Details', {
            sections: [section('Security profile', [['Description', s.securityProfileDescription], ['Targets', (parts.targets || []).map((t) => lastPart(t.arn))], ['Alert targets', Object.keys(s.alertTargets || {})], ['Additional metrics', (s.additionalMetricsToRetainV2 || []).map((m) => m.metric)], ['Created', s.creationDate], ['Modified', s.lastModifiedDate]])],
            tables: [table(['Behavior', 'Metric', 'Condition', 'ML detection'], (s.behaviors || []).map((b) => [b.name, b.metric, b.criteria?.comparisonOperator ? `${b.criteria.comparisonOperator} ${JSON.stringify(b.criteria.value ?? '')}` : undefined, b.criteria?.mlDetectionConfig?.confidenceLevel]), { title: 'Behaviors', emptyMessage: 'No behaviors' })],
          }),
        ],
        tags: tagList(parts.tags),
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown Device Defender page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !id.startsWith('sp:')) throw httpError('Only security profiles can be tagged', 400);
    await iot(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !id.startsWith('sp:')) throw httpError('Only security profiles can be tagged', 400);
    await iot(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('sp:'),
};
