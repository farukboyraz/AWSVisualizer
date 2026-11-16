import { SQSClient, ListQueuesCommand, GetQueueAttributesCommand } from '@aws-sdk/client-sqs';
import { clientConfig } from '../aws/page-common.js';
import { t, type ServiceCards, type CardContext, CardInputError } from './types.js';

/** SQS cards: how many messages wait in a queue. */

const client = (profile: string, region: string) => new SQSClient(clientConfig(profile, region));

function queueOf(ctx: CardContext): string {
  const url = ctx.params.queue || '';
  if (!/^https:\/\/sqs\.[a-z0-9-]+\.amazonaws\.com(\.cn)?\/\d{12}\/[A-Za-z0-9_-]{1,80}(\.fifo)?$/.test(url)) throw new CardInputError(t('Choose a queue', 'Bir kuyruk seç'));
  return url;
}

export const sqsCards: ServiceCards = {
  service: 'sqs',
  options: {
    async 'sqs.queues'({ profile, region }) {
      const urls: string[] = [];
      let NextToken: string | undefined;
      do {
        const res = await client(profile, region).send(new ListQueuesCommand({ NextToken, MaxResults: 1000 }));
        urls.push(...(res.QueueUrls || []));
        NextToken = res.NextToken;
      } while (NextToken);
      return urls.map((url) => ({ value: url, label: url.split('/').pop() || url, detail: url })).sort((a, b) => a.label.localeCompare(b.label));
    },
  },
  templates: [
    {
      id: 'sqs.queueDepth',
      kind: 'metric',
      name: t('Messages in a queue', 'Kuyruktaki mesajlar'),
      description: t('Messages waiting in a queue, with in-flight and delayed ones underneath (AWS approximations).', 'Kuyrukta bekleyen mesajlar; altında işlenen ve gecikmeli olanlar (AWS yaklaşık değerleri).'),
      icon: 'tray.full.fill',
      params: [{ key: 'queue', label: t('Queue', 'Kuyruk'), type: 'combo', source: 'sqs.queues', required: true, maxLength: 300 }],
      async value(ctx) {
        const res = await client(ctx.profile, ctx.region).send(new GetQueueAttributesCommand({ QueueUrl: queueOf(ctx), AttributeNames: ['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', 'ApproximateNumberOfMessagesDelayed'] }));
        const a = res.Attributes || {};
        const inFlight = a.ApproximateNumberOfMessagesNotVisible ?? '0';
        const delayed = a.ApproximateNumberOfMessagesDelayed ?? '0';
        return {
          value: parseInt(a.ApproximateNumberOfMessages ?? '0', 10),
          unit: t('messages', 'mesaj'),
          details: [t(`${inFlight} in flight · ${delayed} delayed`, `${inFlight} işleniyor · ${delayed} gecikmeli`)],
          approximate: true,
        };
      },
      link: (ctx) => ({ service: 'sqs', resource: ctx.params.queue }),
      async preview(ctx) {
        const res = await client(ctx.profile, ctx.region).send(new GetQueueAttributesCommand({ QueueUrl: queueOf(ctx), AttributeNames: ['All'] }));
        const rows = Object.entries(res.Attributes || {})
          .filter(([k]) => !k.endsWith('Policy') && k !== 'RedrivePolicy')
          .map(([k, v]) => [k, /Timestamp$/.test(k) ? new Date(parseInt(v, 10) * 1000).toISOString().slice(0, 16).replace('T', ' ') : v]);
        return {
          title: t(ctx.params.queue?.split('/').pop() ?? '', ctx.params.queue?.split('/').pop() ?? ''),
          columns: [t('Attribute', 'Özellik'), t('Value', 'Değer')],
          rows,
          emptyMessage: t('The queue has no attributes.', 'Kuyruğun özelliği yok.'),
        };
      },
    },
  ],
};
