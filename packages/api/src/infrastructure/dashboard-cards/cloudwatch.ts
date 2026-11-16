import { CloudWatchClient, DescribeAlarmsCommand, type StateValue } from '@aws-sdk/client-cloudwatch';
import { clientConfig } from '../aws/page-common.js';
import { t, type ServiceCards, type CardContext } from './types.js';

/** CloudWatch cards: how many alarms are in a given state. */

const client = (profile: string, region: string) => new CloudWatchClient(clientConfig(profile, region));
const STATES = ['ALARM', 'OK', 'INSUFFICIENT_DATA'];

async function alarms(ctx: CardContext) {
  const state = (STATES.includes(ctx.params.state) ? ctx.params.state : 'ALARM') as StateValue;
  const prefix = ctx.params.prefix?.trim() || undefined;
  const found: { name: string; state: string; reason: string; updated: string }[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client(ctx.profile, ctx.region).send(new DescribeAlarmsCommand({ StateValue: state, AlarmNamePrefix: prefix, AlarmTypes: ['MetricAlarm', 'CompositeAlarm'], NextToken }));
    for (const a of [...(res.MetricAlarms || []), ...(res.CompositeAlarms || [])]) {
      found.push({ name: a.AlarmName || '', state: a.StateValue || '', reason: a.StateReason || '', updated: a.StateUpdatedTimestamp?.toISOString().slice(0, 16).replace('T', ' ') ?? '' });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return found;
}

export const cloudwatchCards: ServiceCards = {
  service: 'cloudwatch',
  templates: [
    {
      id: 'cloudwatch.alarmCount',
      kind: 'metric',
      name: t('Alarms in a state', 'Belirli durumdaki alarmlar'),
      description: t('How many alarms are in ALARM (or OK / insufficient data), optionally only those whose name starts with a prefix.', 'Kaç alarmın ALARM (ya da OK / yetersiz veri) durumunda olduğu; istenirse yalnızca adı belirli bir önekle başlayanlar.'),
      icon: 'bell.badge.fill',
      params: [
        {
          key: 'state',
          label: t('State', 'Durum'),
          type: 'select',
          required: true,
          defaultValue: 'ALARM',
          choices: [
            { value: 'ALARM', label: t('In alarm', 'Alarmda') },
            { value: 'OK', label: t('OK', 'OK') },
            { value: 'INSUFFICIENT_DATA', label: t('Insufficient data', 'Yetersiz veri') },
          ],
        },
        { key: 'prefix', label: t('Name starts with (optional)', 'Ad şununla başlar (isteğe bağlı)'), type: 'text', maxLength: 255 },
      ],
      async value(ctx) {
        return { value: (await alarms(ctx)).length, unit: t('alarms', 'alarm') };
      },
      // The alarm list filtered by the same state and name words.
      link: (ctx) => ({ service: 'cloudwatch', tab: 'alarms', filter: [ctx.params.prefix, ctx.params.state].filter((x) => x && x.trim()).join(' ') || undefined }),
      async preview(ctx) {
        const list = await alarms(ctx);
        return {
          title: t('Matching alarms', 'Eşleşen alarmlar'),
          columns: [t('Alarm', 'Alarm'), t('State', 'Durum'), t('Since', 'Ne zamandan beri'), t('Reason', 'Neden')],
          rows: list.slice(0, 30).map((a) => [a.name, a.state, a.updated, a.reason.length > 80 ? `${a.reason.slice(0, 79)}…` : a.reason]),
          more: list.length > 30,
          emptyMessage: t('No alarms in this state.', 'Bu durumda alarm yok.'),
        };
      },
    },
  ],
};
