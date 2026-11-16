import {
  SESv2Client,
  GetAccountCommand,
  ListEmailIdentitiesCommand,
  GetEmailIdentityCommand,
  ListConfigurationSetsCommand,
  GetConfigurationSetCommand,
  GetConfigurationSetEventDestinationsCommand,
  ListDedicatedIpPoolsCommand,
  GetDedicatedIpsCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-sesv2';
import type { ResourcePage, PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList, clientConfig, byName, accountId, policyJson } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/** Simple Email Service (SES v2): account sending status, verified identities, configuration sets and dedicated IP pools. */
const client = (p: string, r: string) => new SESv2Client(clientConfig(p, r));
const sesArn = async (p: string, r: string, kind: 'identity' | 'configuration-set', name: string) => `arn:aws:ses:${r}:${await accountId(p, r)}:${kind}/${name}`;

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [account, identities, sets, pools] = await Promise.all([
    c.send(new GetAccountCommand({})),
    pageAll((NextToken) => c.send(new ListEmailIdentitiesCommand({ NextToken })), (r) => r.EmailIdentities, (r) => r.NextToken),
    pageAll((NextToken) => c.send(new ListConfigurationSetsCommand({ NextToken })), (r) => r.ConfigurationSets, (r) => r.NextToken).catch(() => [] as string[]),
    pageAll((NextToken) => c.send(new ListDedicatedIpPoolsCommand({ NextToken })), (r) => r.DedicatedIpPools, (r) => r.NextToken).catch(() => [] as string[]),
  ]);
  const q = account.SendQuota;
  return [
    { id: 'account:', name: 'Account', group: 'Account', status: account.ProductionAccessEnabled ? 'PRODUCTION' : 'SANDBOX', info: q ? `${q.SentLast24Hours ?? 0} of ${q.Max24HourSend ?? 0} sent in 24 h · ${q.MaxSendRate ?? 0}/s` : undefined },
    ...identities.map((i) => ({ id: `id:${i.IdentityName}`, name: i.IdentityName || '', group: 'Identities', status: i.VerificationStatus, info: [i.IdentityType, i.SendingEnabled === false && 'sending paused'].filter(Boolean).join(' · ') })).sort(byName),
    ...sets.map((s) => ({ id: `cs:${s}`, name: s, group: 'Configuration sets' })).sort(byName),
    ...pools.map((p) => ({ id: `pool:${p}`, name: p, group: 'Dedicated IP pools' })).sort(byName),
  ];
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, name] = splitId(id);
  const errors: string[] = [];
  if (kind === 'account') {
    const a = await c.send(new GetAccountCommand({}));
    return {
      id,
      title: 'SES account',
      subtitle: a.ProductionAccessEnabled ? 'Production access' : 'Sandbox',
      status: a.EnforcementStatus,
      tabs: [
        tab('Details', {
          sections: [
            section('Sending', [['Production access', a.ProductionAccessEnabled], ['Sending enabled', a.SendingEnabled], ['Enforcement', a.EnforcementStatus], ['Sent (last 24 h)', a.SendQuota?.SentLast24Hours], ['Daily quota', a.SendQuota?.Max24HourSend], ['Max send rate (/s)', a.SendQuota?.MaxSendRate], ['Dedicated IP auto warm-up', a.DedicatedIpAutoWarmupEnabled]]),
            section('Suppression & VDM', [['Suppressed reasons', a.SuppressionAttributes?.SuppressedReasons], ['Virtual Deliverability Manager', a.VdmAttributes?.VdmEnabled], ['Mail type', a.Details?.MailType], ['Website', a.Details?.WebsiteURL]]),
          ],
        }),
      ],
      actions: [],
      errors,
    };
  }
  if (kind === 'id') {
    const i = await c.send(new GetEmailIdentityCommand({ EmailIdentity: name }));
    const dkim = i.DkimAttributes;
    const tabs: PageTab[] = [
      tab('Details', {
        sections: [
          section('Identity', [['Type', i.IdentityType], ['Verification', i.VerificationStatus], ['Verified for sending', i.VerifiedForSendingStatus], ['Feedback forwarding', i.FeedbackForwardingStatus], ['Configuration set', i.ConfigurationSetName], ['Last checked', i.VerificationInfo?.LastCheckedTimestamp], ['Error', i.VerificationInfo?.ErrorType]]),
          section('DKIM', [['Signing', dkim?.SigningEnabled], ['Status', dkim?.Status], ['Origin', dkim?.SigningAttributesOrigin], ['Key length', dkim?.CurrentSigningKeyLength], ['Last rotated', dkim?.LastKeyGenerationTimestamp]]),
          section('MAIL FROM', [['Domain', i.MailFromAttributes?.MailFromDomain], ['Status', i.MailFromAttributes?.MailFromDomainStatus], ['On MX failure', i.MailFromAttributes?.BehaviorOnMxFailure]]),
        ],
        // DKIM CNAMEs are public DNS records the user publishes.
        tables: [table(['Record name', 'Type', 'Value'], (dkim?.Tokens || []).map((t) => [i.IdentityType === 'DOMAIN' ? `${t}._domainkey.${name}` : `${t}._domainkey`, 'CNAME', `${t}.dkim.amazonses.com`]), { title: 'DKIM DNS records', emptyMessage: 'No DKIM tokens (BYODKIM or e-mail address identity)' })],
      }),
    ];
    for (const [policyName, doc] of Object.entries(i.Policies || {})) tabs.push(tab(`Policy: ${policyName}`, { json: policyJson(doc) }));
    return { id, title: name, subtitle: `${i.IdentityType ?? ''} identity`, status: i.VerificationStatus, arn: await sesArn(profile, region, 'identity', name), tabs, tags: tagList(i.Tags), actions: [], errors };
  }
  if (kind === 'cs') {
    const s = await c.send(new GetConfigurationSetCommand({ ConfigurationSetName: name }));
    const arn = await sesArn(profile, region, 'configuration-set', name);
    const parts = await settle({ dest: c.send(new GetConfigurationSetEventDestinationsCommand({ ConfigurationSetName: name })), tags: c.send(new ListTagsForResourceCommand({ ResourceArn: arn })) }, errors);
    return {
      id,
      title: name,
      subtitle: 'Configuration set',
      arn,
      tabs: [
        tab('Details', {
          sections: [section('Configuration set', [['Sending enabled', s.SendingOptions?.SendingEnabled], ['Reputation metrics', s.ReputationOptions?.ReputationMetricsEnabled], ['TLS', s.DeliveryOptions?.TlsPolicy], ['Dedicated IP pool', s.DeliveryOptions?.SendingPoolName], ['Custom tracking domain', s.TrackingOptions?.CustomRedirectDomain], ['Suppression', s.SuppressionOptions?.SuppressedReasons]])],
          tables: [table(['Destination', 'Enabled', 'Events', 'Target'], (parts.dest?.EventDestinations || []).map((d) => [d.Name, d.Enabled, d.MatchingEventTypes, d.SnsDestination?.TopicArn ?? d.KinesisFirehoseDestination?.DeliveryStreamArn ?? d.EventBridgeDestination?.EventBusArn ?? (d.CloudWatchDestination ? 'CloudWatch' : d.PinpointDestination ? 'Pinpoint' : undefined)]), { title: 'Event destinations', emptyMessage: 'No event destinations' })],
        }),
      ],
      tags: tagList(parts.tags?.Tags),
      actions: [],
      errors,
    };
  }
  if (kind === 'pool') {
    const ips = await pageAll((NextToken) => c.send(new GetDedicatedIpsCommand({ PoolName: name, NextToken })), (r) => r.DedicatedIps, (r) => r.NextToken);
    return { id, title: name, subtitle: 'Dedicated IP pool', tabs: [tab('IPs', { tables: [table(['IP', 'Warm-up', 'Warm-up %'], ips.map((x) => [x.Ip, x.WarmupStatus, x.WarmupPercentage]), { emptyMessage: 'No IPs (managed pool or empty)' })] })], actions: [], errors };
  }
  throw httpError(`Unknown SES page: ${id}`, 400);
}

export const sesAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, arn, key, value) {
    if (!arn || !(id.startsWith('id:') || id.startsWith('cs:'))) throw httpError('Only identities and configuration sets can be tagged here', 400);
    await client(profile, region).send(new TagResourceCommand({ ResourceArn: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, arn, key) {
    if (!arn || !(id.startsWith('id:') || id.startsWith('cs:'))) throw httpError('Only identities and configuration sets can be tagged here', 400);
    await client(profile, region).send(new UntagResourceCommand({ ResourceArn: arn, TagKeys: [key] }));
  },
  countable: (row) => row.id.startsWith('id:'),
};
