import {
  SNSClient,
  ListTopicsCommand,
  GetTopicAttributesCommand,
  SetTopicAttributesCommand,
  ListSubscriptionsByTopicCommand,
  SubscribeCommand,
  UnsubscribeCommand,
  PublishCommand,
  CreateTopicCommand,
  DeleteTopicCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-sns';
import { cachedCredentials } from './credential-cache.js';
import type { SnsTopic, SnsTopicDetail, SnsSubscription } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): SNSClient {
  return new SNSClient({ region, credentials: cachedCredentials(profile) });
}

export async function listTopics(profile: string, region: string): Promise<SnsTopic[]> {
  const client = createClient(profile, region);
  const topics: SnsTopic[] = [];
  let nextToken: string | undefined;
  // ListTopics pages at 100 - walked so accounts with more topics aren't cut off.
  do {
    const response = await client.send(new ListTopicsCommand({ NextToken: nextToken }));
    for (const t of response.Topics || []) {
      topics.push({ topicArn: t.TopicArn || '', name: t.TopicArn?.split(':').pop() || '' });
    }
    nextToken = response.NextToken;
  } while (nextToken);
  return topics.sort((a, b) => a.name.localeCompare(b.name));
}

export async function getTopicDetail(profile: string, region: string, topicArn: string): Promise<SnsTopicDetail> {
  const client = createClient(profile, region);
  const [attrRes, tagRes] = await Promise.all([
    client.send(new GetTopicAttributesCommand({ TopicArn: topicArn })),
    client.send(new ListTagsForResourceCommand({ ResourceArn: topicArn })),
  ]);
  const a = attrRes.Attributes || {};
  return {
    topicArn,
    name: topicArn.split(':').pop() || '',
    displayName: a.DisplayName || undefined,
    owner: a.Owner,
    subscriptionsConfirmed: parseInt(a.SubscriptionsConfirmed || '0'),
    subscriptionsPending: parseInt(a.SubscriptionsPending || '0'),
    subscriptionsDeleted: parseInt(a.SubscriptionsDeleted || '0'),
    kmsMasterKeyId: a.KmsMasterKeyId || undefined,
    fifoTopic: a.FifoTopic === 'true',
    contentBasedDeduplication: a.ContentBasedDeduplication === 'true',
    tags: (tagRes.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

/** Raw JSON of one of the topic's policy attributes (`Policy` or `DeliveryPolicy`). */
export async function getTopicPolicy(profile: string, region: string, topicArn: string, attribute: 'Policy' | 'DeliveryPolicy'): Promise<{ policy?: string }> {
  const client = createClient(profile, region);
  const res = await client.send(new GetTopicAttributesCommand({ TopicArn: topicArn }));
  const raw = res.Attributes?.[attribute];
  if (!raw) return {};
  try {
    return { policy: JSON.stringify(JSON.parse(raw), null, 2) };
  } catch {
    return { policy: raw };
  }
}

export async function setTopicAttribute(
  profile: string,
  region: string,
  topicArn: string,
  attribute: 'DisplayName' | 'Policy' | 'DeliveryPolicy',
  value: string
): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new SetTopicAttributesCommand({ TopicArn: topicArn, AttributeName: attribute, AttributeValue: value }));
}

export async function listSubscriptions(profile: string, region: string, topicArn: string): Promise<SnsSubscription[]> {
  const client = createClient(profile, region);
  const subs: SnsSubscription[] = [];
  let nextToken: string | undefined;
  do {
    const res = await client.send(new ListSubscriptionsByTopicCommand({ TopicArn: topicArn, NextToken: nextToken }));
    for (const s of res.Subscriptions || []) {
      // Unconfirmed subscriptions have no real ARN yet - SNS returns the
      // literal string "PendingConfirmation" (and they can't be deleted).
      const pending = s.SubscriptionArn === 'PendingConfirmation';
      subs.push({
        subscriptionArn: s.SubscriptionArn || '',
        protocol: s.Protocol || '',
        endpoint: s.Endpoint || '',
        owner: s.Owner,
        pendingConfirmation: pending,
      });
    }
    nextToken = res.NextToken;
  } while (nextToken && subs.length < 1000);
  return subs;
}

export async function subscribe(profile: string, region: string, topicArn: string, protocol: string, endpoint: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new SubscribeCommand({ TopicArn: topicArn, Protocol: protocol, Endpoint: endpoint, ReturnSubscriptionArn: true }));
}

export async function unsubscribe(profile: string, region: string, subscriptionArn: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new UnsubscribeCommand({ SubscriptionArn: subscriptionArn }));
}

export async function publish(
  profile: string,
  region: string,
  topicArn: string,
  message: string,
  subject?: string,
  messageGroupId?: string,
  messageDeduplicationId?: string
): Promise<{ messageId?: string }> {
  const client = createClient(profile, region);
  const res = await client.send(
    new PublishCommand({
      TopicArn: topicArn,
      Message: message,
      Subject: subject || undefined,
      MessageGroupId: messageGroupId || undefined,
      MessageDeduplicationId: messageDeduplicationId || undefined,
    })
  );
  return { messageId: res.MessageId };
}

export async function createTopic(profile: string, region: string, name: string, fifo: boolean, displayName?: string): Promise<SnsTopic> {
  const client = createClient(profile, region);
  const attributes: Record<string, string> = {};
  if (fifo) attributes.FifoTopic = 'true';
  if (displayName) attributes.DisplayName = displayName;
  // FIFO topic names must end in ".fifo" - appended here so the form
  // doesn't have to teach that rule.
  const finalName = fifo && !name.endsWith('.fifo') ? `${name}.fifo` : name;
  const res = await client.send(new CreateTopicCommand({ Name: finalName, Attributes: attributes }));
  return { topicArn: res.TopicArn || '', name: finalName };
}

export async function deleteTopic(profile: string, region: string, topicArn: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteTopicCommand({ TopicArn: topicArn }));
}

export async function addTopicTag(profile: string, region: string, topicArn: string, key: string, value: string): Promise<SnsTopicDetail> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ ResourceArn: topicArn, Tags: [{ Key: key, Value: value }] }));
  return getTopicDetail(profile, region, topicArn);
}

export async function removeTopicTag(profile: string, region: string, topicArn: string, key: string): Promise<SnsTopicDetail> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ ResourceArn: topicArn, TagKeys: [key] }));
  return getTopicDetail(profile, region, topicArn);
}
