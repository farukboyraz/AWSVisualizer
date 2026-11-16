import {
  SQSClient,
  ListQueuesCommand,
  GetQueueAttributesCommand,
  SetQueueAttributesCommand,
  SendMessageCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
  ListQueueTagsCommand,
  TagQueueCommand,
  UntagQueueCommand,
  PurgeQueueCommand,
} from '@aws-sdk/client-sqs';
import { cachedCredentials } from './credential-cache.js';
import type { SqsQueue, SqsQueueDetail, SqsMessage } from '../../domain/entities/index.js';

function createSqsClient(profile: string, region: string): SQSClient {
  return new SQSClient({ region, credentials: cachedCredentials(profile) });
}

export async function listQueues(profile: string, region: string): Promise<SqsQueue[]> {
  const client = createSqsClient(profile, region);
  const listCmd = new ListQueuesCommand({});
  const listRes = await client.send(listCmd);
  const urls = listRes.QueueUrls || [];

  const queues: SqsQueue[] = [];
  for (const url of urls) {
    try {
      const attrCmd = new GetQueueAttributesCommand({
        QueueUrl: url,
        AttributeNames: [
          'ApproximateNumberOfMessages',
          'ApproximateNumberOfMessagesNotVisible',
          'ApproximateNumberOfMessagesDelayed',
          'VisibilityTimeout',
        ],
      });
      const attrRes = await client.send(attrCmd);
      const attrs = attrRes.Attributes || {};
      queues.push({
        queueUrl: url,
        queueName: url.split('/').pop() || '',
        approximateMessages: parseInt(attrs.ApproximateNumberOfMessages || '0'),
        approximateMessagesNotVisible: parseInt(attrs.ApproximateNumberOfMessagesNotVisible || '0'),
        approximateMessagesDelayed: parseInt(attrs.ApproximateNumberOfMessagesDelayed || '0'),
        visibilityTimeout: parseInt(attrs.VisibilityTimeout || '0'),
      });
    } catch {
      queues.push({
        queueUrl: url,
        queueName: url.split('/').pop() || '',
        approximateMessages: 0,
        approximateMessagesNotVisible: 0,
        approximateMessagesDelayed: 0,
        visibilityTimeout: 0,
      });
    }
  }
  return queues;
}

export async function getQueueDetail(profile: string, region: string, queueUrl: string): Promise<SqsQueueDetail> {
  const client = createSqsClient(profile, region);
  const [attrRes, tagsRes] = await Promise.all([
    client.send(new GetQueueAttributesCommand({ QueueUrl: queueUrl, AttributeNames: ['All'] })),
    client.send(new ListQueueTagsCommand({ QueueUrl: queueUrl })),
  ]);
  const attrs = attrRes.Attributes || {};
  const tags = Object.entries(tagsRes.Tags || {}).map(([key, value]) => ({ key, value: value || '' }));
  const redrive = parseRedrivePolicy(attrs.RedrivePolicy);

  return {
    queueUrl,
    queueName: queueUrl.split('/').pop() || '',
    arn: attrs.QueueArn,
    approximateMessages: parseInt(attrs.ApproximateNumberOfMessages || '0'),
    approximateMessagesNotVisible: parseInt(attrs.ApproximateNumberOfMessagesNotVisible || '0'),
    approximateMessagesDelayed: parseInt(attrs.ApproximateNumberOfMessagesDelayed || '0'),
    visibilityTimeout: parseInt(attrs.VisibilityTimeout || '0'),
    messageRetentionPeriod: parseInt(attrs.MessageRetentionPeriod || '0'),
    delaySeconds: parseInt(attrs.DelaySeconds || '0'),
    receiveMessageWaitTimeSeconds: parseInt(attrs.ReceiveMessageWaitTimeSeconds || '0'),
    maximumMessageSize: parseInt(attrs.MaximumMessageSize || '0'),
    fifoQueue: attrs.FifoQueue === 'true',
    contentBasedDeduplication: attrs.ContentBasedDeduplication === 'true',
    kmsMasterKeyId: attrs.KmsMasterKeyId,
    createdTimestamp: attrs.CreatedTimestamp ? new Date(parseInt(attrs.CreatedTimestamp) * 1000).toISOString() : undefined,
    lastModifiedTimestamp: attrs.LastModifiedTimestamp ? new Date(parseInt(attrs.LastModifiedTimestamp) * 1000).toISOString() : undefined,
    tags,
    policy: attrs.Policy || undefined,
    deadLetterTargetArn: redrive?.deadLetterTargetArn,
    maxReceiveCount: redrive?.maxReceiveCount,
    sqsManagedSseEnabled: attrs.SqsManagedSseEnabled === 'true',
    kmsDataKeyReusePeriodSeconds: attrs.KmsDataKeyReusePeriodSeconds ? parseInt(attrs.KmsDataKeyReusePeriodSeconds) : undefined,
    fifoThroughputLimit: attrs.FifoThroughputLimit,
    deduplicationScope: attrs.DeduplicationScope,
  };
}

/** RedrivePolicy is a JSON string; maxReceiveCount may arrive as a string or number. */
function parseRedrivePolicy(raw: string | undefined): { deadLetterTargetArn?: string; maxReceiveCount?: number } | undefined {
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as { deadLetterTargetArn?: string; maxReceiveCount?: string | number };
    const count = parsed.maxReceiveCount === undefined ? undefined : Number(parsed.maxReceiveCount);
    return { deadLetterTargetArn: parsed.deadLetterTargetArn, maxReceiveCount: Number.isFinite(count) ? count : undefined };
  } catch {
    return undefined;
  }
}

/** Deletes every message in the queue (SQS allows one purge per 60 s). */
export async function purgeQueue(profile: string, region: string, queueUrl: string): Promise<SqsQueueDetail> {
  const client = createSqsClient(profile, region);
  await client.send(new PurgeQueueCommand({ QueueUrl: queueUrl }));
  return getQueueDetail(profile, region, queueUrl);
}

export async function updateQueueAttributes(
  profile: string,
  region: string,
  queueUrl: string,
  attributes: Record<string, string>
): Promise<SqsQueueDetail> {
  const client = createSqsClient(profile, region);
  await client.send(new SetQueueAttributesCommand({ QueueUrl: queueUrl, Attributes: attributes }));
  return getQueueDetail(profile, region, queueUrl);
}

export async function sendMessage(
  profile: string,
  region: string,
  queueUrl: string,
  body: string,
  delaySeconds?: number,
  messageGroupId?: string,
  messageDeduplicationId?: string
): Promise<string | undefined> {
  const client = createSqsClient(profile, region);
  const response = await client.send(
    new SendMessageCommand({
      QueueUrl: queueUrl,
      MessageBody: body,
      DelaySeconds: delaySeconds,
      MessageGroupId: messageGroupId,
      MessageDeduplicationId: messageDeduplicationId,
    })
  );
  return response.MessageId;
}

export async function receiveMessages(profile: string, region: string, queueUrl: string, maxMessages = 10): Promise<SqsMessage[]> {
  const client = createSqsClient(profile, region);
  const response = await client.send(
    new ReceiveMessageCommand({
      QueueUrl: queueUrl,
      MaxNumberOfMessages: Math.min(Math.max(maxMessages, 1), 10),
      MessageSystemAttributeNames: ['SentTimestamp', 'ApproximateReceiveCount'],
      WaitTimeSeconds: 1,
    })
  );

  return (response.Messages || []).map((m) => ({
    messageId: m.MessageId || '',
    receiptHandle: m.ReceiptHandle || '',
    body: m.Body || '',
    sentTimestamp: m.Attributes?.SentTimestamp ? new Date(parseInt(m.Attributes.SentTimestamp)).toISOString() : undefined,
    approximateReceiveCount: m.Attributes?.ApproximateReceiveCount ? parseInt(m.Attributes.ApproximateReceiveCount) : undefined,
  }));
}

export async function deleteMessage(profile: string, region: string, queueUrl: string, receiptHandle: string): Promise<void> {
  const client = createSqsClient(profile, region);
  await client.send(new DeleteMessageCommand({ QueueUrl: queueUrl, ReceiptHandle: receiptHandle }));
}

export async function addQueueTag(profile: string, region: string, queueUrl: string, key: string, value: string): Promise<SqsQueueDetail> {
  const client = createSqsClient(profile, region);
  await client.send(new TagQueueCommand({ QueueUrl: queueUrl, Tags: { [key]: value } }));
  return getQueueDetail(profile, region, queueUrl);
}

export async function removeQueueTag(profile: string, region: string, queueUrl: string, key: string): Promise<SqsQueueDetail> {
  const client = createSqsClient(profile, region);
  await client.send(new UntagQueueCommand({ QueueUrl: queueUrl, TagKeys: [key] }));
  return getQueueDetail(profile, region, queueUrl);
}
