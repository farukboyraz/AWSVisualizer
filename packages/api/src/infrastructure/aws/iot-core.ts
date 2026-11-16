import {
  IoTClient,
  DescribeEndpointCommand,
  GetV2LoggingOptionsCommand,
  ListThingsCommand,
  DescribeThingCommand,
  ListThingPrincipalsCommand,
  ListThingGroupsForThingCommand,
  ListThingGroupsCommand,
  DescribeThingGroupCommand,
  ListThingsInThingGroupCommand,
  ListThingTypesCommand,
  ListPoliciesCommand,
  GetPolicyCommand,
  ListTargetsForPolicyCommand,
  ListCertificatesCommand,
  DescribeCertificateCommand,
  ListTopicRulesCommand,
  GetTopicRuleCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type Action,
} from '@aws-sdk/client-iot';
import type { PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, lastPart, policyJson, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const THING_LIMIT = 500;
const CERT_LIMIT = 200;

/** IoT Core. */
export const iot = (p: string, r: string) => new IoTClient(clientConfig(p, r));
export const iotTags = (c: IoTClient, arn?: string) => (arn ? pageAll((nextToken) => c.send(new ListTagsForResourceCommand({ resourceArn: arn, nextToken })), (r) => r.tags, (r) => r.nextToken) : Promise.resolve([]));

/** One line per rule action: its type and target. Credentials (HTTP headers, Salesforce token…) are left out. */
function actionText(a: Action): [string, string] {
  const entry = Object.entries(a).find(([, v]) => v);
  if (!entry) return ['-', '-'];
  const [type, v] = entry as [string, Record<string, unknown>];
  const target = ['functionArn', 'targetArn', 'queueUrl', 'streamName', 'deliveryStreamName', 'bucketName', 'tableName', 'topic', 'logGroupName', 'alarmName', 'metricName', 'endpoint', 'stateMachineName', 'channelName', 'inputName', 'clusterArn', 'destinationArn']
    .map((k) => v[k])
    .find((x) => typeof x === 'string') as string | undefined;
  const url = typeof v.url === 'string' ? v.url.replace(/\/\/[^@/\s]+@/, '//••••@') : undefined;
  return [type, target ?? url ?? '-'];
}

export const iotCoreAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const c = iot(profile, region);
    const [things, groups, types, policies, rules, certs] = await Promise.all([
      pageAll((nextToken) => c.send(new ListThingsCommand({ nextToken, maxResults: 250 })), (r) => r.things, (r) => r.nextToken, THING_LIMIT),
      pageAll((nextToken) => c.send(new ListThingGroupsCommand({ nextToken })), (r) => r.thingGroups, (r) => r.nextToken).catch(() => []),
      pageAll((nextToken) => c.send(new ListThingTypesCommand({ nextToken })), (r) => r.thingTypes, (r) => r.nextToken).catch(() => []),
      pageAll((marker) => c.send(new ListPoliciesCommand({ marker })), (r) => r.policies, (r) => r.nextMarker).catch(() => []),
      pageAll((nextToken) => c.send(new ListTopicRulesCommand({ nextToken })), (r) => r.rules, (r) => r.nextToken).catch(() => []),
      pageAll((marker) => c.send(new ListCertificatesCommand({ marker, pageSize: 100 })), (r) => r.certificates, (r) => r.nextMarker, CERT_LIMIT).catch(() => []),
    ]);
    return [
      { id: 'settings:', name: 'Endpoints & settings', group: 'Account', info: 'Device data endpoint, logging' },
      ...things.map((t) => ({ id: `thing:${t.thingName}`, name: t.thingName || '', group: things.length >= THING_LIMIT ? `Things (first ${THING_LIMIT})` : 'Things', info: t.thingTypeName })).sort(byName),
      ...groups.map((g) => ({ id: `tg:${g.groupName}`, name: g.groupName || '', group: 'Thing groups' })).sort(byName),
      ...types.map((t) => ({ id: `tt:${t.thingTypeName}`, name: t.thingTypeName || '', group: 'Thing types', status: t.thingTypeMetadata?.deprecated ? 'DEPRECATED' : undefined, info: t.thingTypeProperties?.thingTypeDescription })).sort(byName),
      ...policies.map((p) => ({ id: `pol:${p.policyName}`, name: p.policyName || '', group: 'Policies' })).sort(byName),
      ...rules.map((r) => ({ id: `rule:${r.ruleName}`, name: r.ruleName || '', group: 'Message routing rules', status: r.ruleDisabled ? 'DISABLED' : 'ENABLED', info: r.topicPattern })).sort(byName),
      ...certs.map((x) => ({ id: `cert:${x.certificateId}`, name: `${x.certificateId?.slice(0, 12)}…`, group: certs.length >= CERT_LIMIT ? `Certificates (first ${CERT_LIMIT})` : 'Certificates', status: x.status, info: x.creationDate?.toISOString().slice(0, 10) })),
    ];
  },
  async detail(profile, region, id) {
    const c = iot(profile, region);
    const [kind, name] = splitId(id);
    const errors: string[] = [];
    if (kind === 'settings') {
      const parts = await settle(
        {
          data: c.send(new DescribeEndpointCommand({ endpointType: 'iot:Data-ATS' })),
          creds: c.send(new DescribeEndpointCommand({ endpointType: 'iot:CredentialProvider' })),
          jobs: c.send(new DescribeEndpointCommand({ endpointType: 'iot:Jobs' })),
          logging: c.send(new GetV2LoggingOptionsCommand({})),
        },
        errors,
        (err) => (err as { name?: string })?.name === 'NotConfiguredException',
      );
      return {
        id,
        title: 'Endpoints & settings',
        subtitle: 'IoT Core account settings',
        tabs: [
          tab('Settings', {
            sections: [
              { title: 'Endpoints', settings: [], copyable: [parts.data?.endpointAddress && { label: 'Device data (ATS)', value: parts.data.endpointAddress }, parts.creds?.endpointAddress && { label: 'Credential provider', value: parts.creds.endpointAddress }, parts.jobs?.endpointAddress && { label: 'Jobs', value: parts.jobs.endpointAddress }].filter((x): x is { label: string; value: string } => Boolean(x)) },
              section('Logging', [['Default level', parts.logging?.defaultLogLevel ?? 'Not configured'], ['Disabled', parts.logging?.disableAllLogs], ['Role', parts.logging?.roleArn]]),
            ],
          }),
        ],
        actions: [],
        errors,
      };
    }
    if (kind === 'thing') {
      const t = await c.send(new DescribeThingCommand({ thingName: name }));
      const parts = await settle(
        {
          principals: pageAll((nextToken) => c.send(new ListThingPrincipalsCommand({ thingName: name, nextToken })), (r) => r.principals, (r) => r.nextToken),
          groups: pageAll((nextToken) => c.send(new ListThingGroupsForThingCommand({ thingName: name, nextToken })), (r) => r.thingGroups, (r) => r.nextToken),
        },
        errors,
      );
      return {
        id,
        title: name,
        subtitle: t.thingTypeName ? `Thing · ${t.thingTypeName}` : 'Thing',
        arn: t.thingArn,
        tabs: [
          tab('Details', {
            sections: [section('Thing', [['Thing ID', t.thingId], ['Type', t.thingTypeName], ['Billing group', t.billingGroupName], ['Groups', (parts.groups || []).map((g) => g.groupName)], ['Version', t.version]])],
            tables: [
              table(['Attribute', 'Value'], Object.entries(t.attributes || {}), { title: 'Attributes', emptyMessage: 'No attributes' }),
              table(['Principal', 'Kind'], (parts.principals || []).map((p) => [lastPart(p), p.includes(':cert/') ? 'Certificate' : p.includes(':cognito') ? 'Cognito identity' : 'Other']), { title: 'Attached principals', emptyMessage: 'No certificates attached' }),
            ],
          }),
        ],
        actions: [],
        errors,
      };
    }
    if (kind === 'tg') {
      const g = await c.send(new DescribeThingGroupCommand({ thingGroupName: name }));
      const parts = await settle({ things: pageAll((nextToken) => c.send(new ListThingsInThingGroupCommand({ thingGroupName: name, nextToken })), (r) => r.things, (r) => r.nextToken, THING_LIMIT), tags: iotTags(c, g.thingGroupArn) }, errors);
      return {
        id,
        title: name,
        subtitle: g.queryString ? 'Dynamic thing group' : 'Thing group',
        status: g.status,
        arn: g.thingGroupArn,
        tabs: [
          tab('Details', {
            sections: [section('Group', [['Description', g.thingGroupProperties?.thingGroupDescription], ['Parent', g.thingGroupMetadata?.parentGroupName], ['Query', g.queryString], ['Created', g.thingGroupMetadata?.creationDate]])],
            tables: [table(['Thing'], (parts.things || []).map((t) => [t]), { title: 'Things', emptyMessage: 'No things' })],
          }),
        ],
        tags: tagList(parts.tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'tt') {
      const t = (await pageAll((nextToken) => c.send(new ListThingTypesCommand({ nextToken, thingTypeName: name })), (r) => r.thingTypes, (r) => r.nextToken))[0];
      if (!t) throw httpError(`Thing type not found: ${name}`, 404);
      const { tags } = await settle({ tags: iotTags(c, t.thingTypeArn) }, errors);
      return {
        id,
        title: name,
        subtitle: 'Thing type',
        status: t.thingTypeMetadata?.deprecated ? 'DEPRECATED' : undefined,
        arn: t.thingTypeArn,
        tabs: [tab('Details', { sections: [section('Thing type', [['Description', t.thingTypeProperties?.thingTypeDescription], ['Searchable attributes', t.thingTypeProperties?.searchableAttributes], ['Deprecated', t.thingTypeMetadata?.deprecated], ['Created', t.thingTypeMetadata?.creationDate]])] })],
        tags: tagList(tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'pol') {
      const p = await c.send(new GetPolicyCommand({ policyName: name }));
      const parts = await settle({ targets: pageAll((marker) => c.send(new ListTargetsForPolicyCommand({ policyName: name, marker })), (r) => r.targets, (r) => r.nextMarker), tags: iotTags(c, p.policyArn) }, errors);
      return {
        id,
        title: name,
        subtitle: 'IoT policy',
        arn: p.policyArn,
        tabs: [
          tab('Details', {
            sections: [section('Policy', [['Default version', p.defaultVersionId], ['Created', p.creationDate], ['Modified', p.lastModifiedDate]])],
            tables: [table(['Attached to'], (parts.targets || []).map((t) => [lastPart(t)]), { title: 'Targets', emptyMessage: 'Not attached' })],
          }),
          tab('Document', { json: policyJson(p.policyDocument) }),
        ],
        tags: tagList(parts.tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'rule') {
      const r = await c.send(new GetTopicRuleCommand({ ruleName: name }));
      const rule = r.rule;
      const { tags } = await settle({ tags: iotTags(c, r.ruleArn) }, errors);
      return {
        id,
        title: name,
        subtitle: 'Message routing rule',
        status: rule?.ruleDisabled ? 'DISABLED' : 'ENABLED',
        arn: r.ruleArn,
        tabs: [
          tab('Details', {
            sections: [section('Rule', [['SQL', rule?.sql], ['SQL version', rule?.awsIotSqlVersion], ['Description', rule?.description], ['Error action', rule?.errorAction ? actionText(rule.errorAction).join(' → ') : undefined], ['Created', rule?.createdAt]])],
            tables: [table(['Action', 'Target'], (rule?.actions || []).map(actionText), { title: 'Actions', emptyMessage: 'No actions' })],
          }),
        ],
        tags: tagList(tags),
        actions: [],
        errors,
      };
    }
    if (kind === 'cert') {
      // Metadata only - the certificate PEM is not fetched.
      const d = (await c.send(new DescribeCertificateCommand({ certificateId: name }))).certificateDescription;
      return {
        id,
        title: `Certificate ${name.slice(0, 12)}…`,
        subtitle: d?.certificateMode === 'SNI_ONLY' ? 'SNI-only certificate' : 'Device certificate',
        status: d?.status,
        arn: d?.certificateArn,
        tabs: [tab('Details', { sections: [section('Certificate', [['Certificate ID', d?.certificateId], ['Status', d?.status], ['Mode', d?.certificateMode], ['CA certificate', d?.caCertificateId], ['Owner', d?.ownedBy], ['Valid from', d?.validity?.notBefore], ['Valid until', d?.validity?.notAfter], ['Created', d?.creationDate], ['Modified', d?.lastModifiedDate]])] })],
        actions: [],
        errors,
      };
    }
    throw httpError(`Unknown IoT Core page: ${id}`, 400);
  },
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !/^(tg|tt|pol|rule):/.test(id)) throw httpError('Only thing groups, thing types, policies and rules can be tagged here', 400);
    await iot(profile, region).send(new TagResourceCommand({ resourceArn: arn, tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !/^(tg|tt|pol|rule):/.test(id)) throw httpError('Only thing groups, thing types, policies and rules can be tagged here', 400);
    await iot(profile, region).send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('thing:'),
};
