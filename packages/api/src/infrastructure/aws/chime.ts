import {
  ChimeSDKVoiceClient,
  ListVoiceConnectorsCommand,
  GetVoiceConnectorCommand,
  GetVoiceConnectorTerminationCommand,
  GetVoiceConnectorOriginationCommand,
  ListVoiceConnectorGroupsCommand,
  ListPhoneNumbersCommand,
  ListSipMediaApplicationsCommand,
  GetSipMediaApplicationCommand,
  ListSipRulesCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-chime-sdk-voice';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/**
 * Chime: the Amazon Chime app was shut down on 20 February 2026; the
 * Chime SDK (PSTN / SIP voice for your own apps) continues, so this page
 * shows Chime SDK Voice: Voice Connectors, phone numbers, SIP media
 * applications and SIP rules.
 */
const client = (p: string, r: string) => new ChimeSDKVoiceClient(clientConfig(p, r));
const NUMBER_LIMIT = 500;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [connectors, groups, numbers, apps, rules] = await Promise.all([
    pageAll((NextToken) => c.send(new ListVoiceConnectorsCommand({ NextToken })), (r) => r.VoiceConnectors, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListVoiceConnectorGroupsCommand({ NextToken })), (r) => r.VoiceConnectorGroups, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListPhoneNumbersCommand({ NextToken })), (r) => r.PhoneNumbers, (r) => r.NextToken, NUMBER_LIMIT).catch(() => []),
    pageAll((NextToken) => c.send(new ListSipMediaApplicationsCommand({ NextToken })), (r) => r.SipMediaApplications, (r) => r.NextToken).catch(() => []),
    pageAll((NextToken) => c.send(new ListSipRulesCommand({ NextToken })), (r) => r.SipRules, (r) => r.NextToken).catch(() => []),
  ]);
  return [
    ...connectors.map((v) => ({ id: `vc:${v.VoiceConnectorId}`, name: v.Name || v.VoiceConnectorId || '', group: 'Voice Connectors', info: [v.OutboundHostName, v.RequireEncryption && 'encrypted'].filter(Boolean).join(' · ') })).sort(byName),
    ...groups.map((g) => ({ id: `vcg:${g.VoiceConnectorGroupId}`, name: g.Name || '', group: 'Voice Connector groups', info: `${g.VoiceConnectorItems?.length ?? 0} connectors` })).sort(byName),
    ...apps.map((a) => ({ id: `sma:${a.SipMediaApplicationId}`, name: a.Name || '', group: 'SIP media applications', info: a.AwsRegion })).sort(byName),
    ...rules.map((r) => ({ id: `rule:${r.SipRuleId}`, name: r.Name || '', group: 'SIP rules', status: r.Disabled ? 'DISABLED' : 'ENABLED', info: `${r.TriggerType}: ${r.TriggerValue}` })).sort(byName),
    ...numbers.map((n) => ({ id: `num:${n.PhoneNumberId}`, name: n.E164PhoneNumber || n.PhoneNumberId || '', group: numbers.length >= NUMBER_LIMIT ? `Phone numbers (first ${NUMBER_LIMIT})` : 'Phone numbers', status: n.Status, info: [n.ProductType, n.Country].filter(Boolean).join(' · ') })),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  const errors: string[] = [];
  const tags = async (arn?: string) => (arn ? (await settle({ t: c.send(new ListTagsForResourceCommand({ ResourceARN: arn })) }, errors)).t?.Tags : undefined);
  if (kind === 'vc') {
    const v = (await c.send(new GetVoiceConnectorCommand({ VoiceConnectorId: rest }))).VoiceConnector;
    if (!v) throw httpError(`Voice Connector not found: ${rest}`, 404);
    // Termination: calling plan and allowed CIDRs only (SIP credentials are never read).
    const parts = await settle({ term: c.send(new GetVoiceConnectorTerminationCommand({ VoiceConnectorId: rest })), orig: c.send(new GetVoiceConnectorOriginationCommand({ VoiceConnectorId: rest })) }, errors, (err) => (err as { name?: string })?.name === 'NotFoundException');
    const t = parts.term?.Termination;
    return {
      id,
      title: v.Name || rest,
      subtitle: 'Chime SDK Voice Connector',
      arn: v.VoiceConnectorArn,
      tabs: [
        tab('Details', {
          sections: [
            section('Voice Connector', [['Outbound host', v.OutboundHostName], ['Region', v.AwsRegion], ['Encryption required', v.RequireEncryption], ['Created', v.CreatedTimestamp], ['Updated', v.UpdatedTimestamp]], { note: 'The Amazon Chime app was shut down on 20 February 2026; Chime SDK voice keeps working.' }),
            section('Termination (outbound)', [['Enabled', t ? !t.Disabled : undefined], ['Calling regions', t?.CallingRegions], ['Allowed CIDRs', t?.CidrAllowedList], ['Default caller ID', t?.DefaultPhoneNumber], ['Max calls / s', t?.CpsLimit]]),
          ],
          tables: [table(['Host', 'Port', 'Protocol', 'Priority', 'Weight'], (parts.orig?.Origination?.Routes || []).map((r) => [r.Host, r.Port, r.Protocol, r.Priority, r.Weight]), { title: `Origination (inbound)${parts.orig?.Origination?.Disabled ? ' - disabled' : ''}`, emptyMessage: 'No origination routes' })],
        }),
      ],
      tags: tagList(await tags(v.VoiceConnectorArn)),
      actions: [],
      errors,
    };
  }
  if (kind === 'sma') {
    const a = (await c.send(new GetSipMediaApplicationCommand({ SipMediaApplicationId: rest }))).SipMediaApplication;
    if (!a) throw httpError(`SIP media application not found: ${rest}`, 404);
    return {
      id,
      title: a.Name || rest,
      subtitle: 'SIP media application',
      arn: a.SipMediaApplicationArn,
      tabs: [tab('Details', { sections: [section('Application', [['Region', a.AwsRegion], ['Lambda endpoints', (a.Endpoints || []).map((e) => lastPart(e.LambdaArn))], ['Created', a.CreatedTimestamp], ['Updated', a.UpdatedTimestamp]])] })],
      tags: tagList(await tags(a.SipMediaApplicationArn)),
      actions: [],
      errors,
    };
  }
  if (kind === 'vcg' || kind === 'rule' || kind === 'num') {
    const rows =
      kind === 'vcg'
        ? (await pageAll((NextToken) => c.send(new ListVoiceConnectorGroupsCommand({ NextToken })), (r) => r.VoiceConnectorGroups, (r) => r.NextToken)).filter((g) => g.VoiceConnectorGroupId === rest).map((g) => ({ title: g.Name || rest, subtitle: 'Voice Connector group', arn: g.VoiceConnectorGroupArn, pairs: [['Connectors', (g.VoiceConnectorItems || []).map((i) => `${i.VoiceConnectorId} (priority ${i.Priority})`)], ['Created', g.CreatedTimestamp]] as [string, unknown][] }))
        : kind === 'rule'
          ? (await pageAll((NextToken) => c.send(new ListSipRulesCommand({ NextToken })), (r) => r.SipRules, (r) => r.NextToken)).filter((r) => r.SipRuleId === rest).map((r) => ({ title: r.Name || rest, subtitle: 'SIP rule', arn: undefined, pairs: [['Trigger', `${r.TriggerType}: ${r.TriggerValue}`], ['Enabled', !r.Disabled], ['Targets', (r.TargetApplications || []).map((t) => `${t.SipMediaApplicationId} (${t.AwsRegion}, priority ${t.Priority})`)], ['Created', r.CreatedTimestamp]] as [string, unknown][] }))
          : (await pageAll((NextToken) => c.send(new ListPhoneNumbersCommand({ NextToken })), (r) => r.PhoneNumbers, (r) => r.NextToken)).filter((n) => n.PhoneNumberId === rest).map((n) => ({ title: n.E164PhoneNumber || rest, subtitle: 'Phone number', arn: undefined, pairs: [['Status', n.Status], ['Type', n.Type], ['Product', n.ProductType], ['Country', n.Country], ['Calling name', n.CallingName], ['Inbound / outbound calls', `${n.Capabilities?.InboundCall ? 'yes' : 'no'} / ${n.Capabilities?.OutboundCall ? 'yes' : 'no'}`], ['SMS', n.Capabilities?.InboundSMS || n.Capabilities?.OutboundSMS], ['Associated with', (n.Associations || []).map((a) => `${a.Name}: ${a.Value}`)], ['Created', n.CreatedTimestamp]] as [string, unknown][] }));
    const x = rows[0];
    if (!x) throw httpError(`Not found: ${rest}`, 404);
    return { id, title: x.title, subtitle: x.subtitle, arn: x.arn, tabs: [tab('Details', { sections: [section(x.subtitle, x.pairs)] })], tags: x.arn ? tagList(await tags(x.arn)) : undefined, actions: [], errors };
  }
  throw httpError(`Unknown Chime page: ${id}`, 400);
}

export const chimeAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('This resource has no tags', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('This resource has no tags', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('vc:') || row.id.startsWith('sma:'),
};
