import {
  CloudWatchClient,
  DescribeAlarmsCommand,
  PutMetricAlarmCommand,
  DeleteAlarmsCommand,
  EnableAlarmActionsCommand,
  DisableAlarmActionsCommand,
  type MetricAlarm,
} from '@aws-sdk/client-cloudwatch';
import {
  CloudWatchLogsClient,
  DescribeLogGroupsCommand,
  DescribeLogStreamsCommand,
  GetLogEventsCommand,
  PutRetentionPolicyCommand,
  DeleteRetentionPolicyCommand,
  DeleteLogGroupCommand,
} from '@aws-sdk/client-cloudwatch-logs';
import { cachedCredentials } from './credential-cache.js';
import type { CloudWatchAlarm, CloudWatchAlarmDetail, LogGroup, LogStreamInfo, LogEventInfo } from '../../domain/entities/index.js';

function createAlarmsClient(profile: string, region: string): CloudWatchClient {
  return new CloudWatchClient({ region, credentials: cachedCredentials(profile) });
}

function createLogsClient(profile: string, region: string): CloudWatchLogsClient {
  return new CloudWatchLogsClient({ region, credentials: cachedCredentials(profile) });
}

export async function listAlarms(profile: string, region: string): Promise<CloudWatchAlarm[]> {
  const client = createAlarmsClient(profile, region);
  const response = await client.send(new DescribeAlarmsCommand({}));

  return (response.MetricAlarms || []).map((a) => ({
    alarmName: a.AlarmName || '',
    state: a.StateValue || '',
    metricName: a.MetricName || '',
    namespace: a.Namespace || '',
    threshold: a.Threshold,
    comparisonOperator: a.ComparisonOperator,
  }));
}

function mapAlarmDetail(a: MetricAlarm): CloudWatchAlarmDetail {
  return {
    alarmName: a.AlarmName || '',
    alarmArn: a.AlarmArn,
    alarmDescription: a.AlarmDescription,
    state: a.StateValue || '',
    stateReason: a.StateReason,
    actionsEnabled: a.ActionsEnabled ?? true,
    okActions: a.OKActions || [],
    alarmActions: a.AlarmActions || [],
    insufficientDataActions: a.InsufficientDataActions || [],
    metricName: a.MetricName || '',
    namespace: a.Namespace || '',
    statistic: a.Statistic,
    extendedStatistic: a.ExtendedStatistic,
    period: a.Period,
    evaluationPeriods: a.EvaluationPeriods,
    datapointsToAlarm: a.DatapointsToAlarm,
    threshold: a.Threshold,
    comparisonOperator: a.ComparisonOperator,
    treatMissingData: a.TreatMissingData,
    unit: a.Unit,
    dimensions: (a.Dimensions || []).map((d) => ({ name: d.Name || '', value: d.Value || '' })),
  };
}

async function fetchAlarm(client: CloudWatchClient, alarmName: string): Promise<MetricAlarm> {
  const response = await client.send(new DescribeAlarmsCommand({ AlarmNames: [alarmName] }));
  const alarm = response.MetricAlarms?.[0];
  if (!alarm) {
    throw new Error(`Alarm not found: ${alarmName}`);
  }
  return alarm;
}

export async function getAlarmDetail(profile: string, region: string, alarmName: string): Promise<CloudWatchAlarmDetail> {
  const client = createAlarmsClient(profile, region);
  return mapAlarmDetail(await fetchAlarm(client, alarmName));
}

export interface AlarmThresholdUpdate {
  threshold: number;
  comparisonOperator: string;
  evaluationPeriods: number;
  period: number;
}

// PutMetricAlarm always fully replaces the alarm definition (no partial
// update API), so we re-fetch the existing alarm and send every field back
// unchanged except the ones the user actually edited - same as the AWS
// console's "Edit" form does under the hood.
export async function updateAlarmThreshold(profile: string, region: string, alarmName: string, update: AlarmThresholdUpdate): Promise<CloudWatchAlarmDetail> {
  const client = createAlarmsClient(profile, region);
  const existing = await fetchAlarm(client, alarmName);

  await client.send(
    new PutMetricAlarmCommand({
      AlarmName: existing.AlarmName,
      AlarmDescription: existing.AlarmDescription,
      ActionsEnabled: existing.ActionsEnabled,
      OKActions: existing.OKActions,
      AlarmActions: existing.AlarmActions,
      InsufficientDataActions: existing.InsufficientDataActions,
      MetricName: existing.MetricName,
      Namespace: existing.Namespace,
      Statistic: existing.Statistic,
      ExtendedStatistic: existing.ExtendedStatistic,
      Dimensions: existing.Dimensions,
      Unit: existing.Unit,
      DatapointsToAlarm: existing.DatapointsToAlarm,
      TreatMissingData: existing.TreatMissingData,
      EvaluateLowSampleCountPercentile: existing.EvaluateLowSampleCountPercentile,
      Threshold: update.threshold,
      ComparisonOperator: update.comparisonOperator as MetricAlarm['ComparisonOperator'],
      EvaluationPeriods: update.evaluationPeriods,
      Period: update.period,
    })
  );

  return getAlarmDetail(profile, region, alarmName);
}

export async function setAlarmActionsEnabled(profile: string, region: string, alarmName: string, enabled: boolean): Promise<CloudWatchAlarmDetail> {
  const client = createAlarmsClient(profile, region);
  await client.send(
    enabled ? new EnableAlarmActionsCommand({ AlarmNames: [alarmName] }) : new DisableAlarmActionsCommand({ AlarmNames: [alarmName] })
  );
  return getAlarmDetail(profile, region, alarmName);
}

export async function deleteAlarm(profile: string, region: string, alarmName: string): Promise<void> {
  const client = createAlarmsClient(profile, region);
  await client.send(new DeleteAlarmsCommand({ AlarmNames: [alarmName] }));
}

export async function listLogGroups(profile: string, region: string): Promise<LogGroup[]> {
  const client = createLogsClient(profile, region);
  const command = new DescribeLogGroupsCommand({});
  const response = await client.send(command);

  return (response.logGroups || []).map((lg) => ({
    logGroupName: lg.logGroupName || '',
    storedBytes: lg.storedBytes || 0,
    retentionInDays: lg.retentionInDays,
    creationTime: lg.creationTime,
  }));
}

export async function listLogStreams(profile: string, region: string, logGroupName: string, limit = 50): Promise<LogStreamInfo[]> {
  const client = createLogsClient(profile, region);
  const response = await client.send(
    new DescribeLogStreamsCommand({ logGroupName, orderBy: 'LastEventTime', descending: true, limit })
  );

  return (response.logStreams || []).map((s) => ({
    logStreamName: s.logStreamName || '',
    creationTime: s.creationTime,
    firstEventTimestamp: s.firstEventTimestamp,
    lastEventTimestamp: s.lastEventTimestamp,
    storedBytes: s.storedBytes,
  }));
}

export async function getLogEvents(profile: string, region: string, logGroupName: string, logStreamName: string, limit = 200): Promise<LogEventInfo[]> {
  const client = createLogsClient(profile, region);
  const response = await client.send(
    new GetLogEventsCommand({ logGroupName, logStreamName, limit, startFromHead: false })
  );

  return (response.events || []).map((e) => ({
    timestamp: e.timestamp,
    message: e.message,
  }));
}

export async function setLogGroupRetention(profile: string, region: string, logGroupName: string, retentionInDays: number | null): Promise<void> {
  const client = createLogsClient(profile, region);
  if (retentionInDays === null) {
    await client.send(new DeleteRetentionPolicyCommand({ logGroupName }));
  } else {
    await client.send(new PutRetentionPolicyCommand({ logGroupName, retentionInDays }));
  }
}

export async function deleteLogGroup(profile: string, region: string, logGroupName: string): Promise<void> {
  const client = createLogsClient(profile, region);
  await client.send(new DeleteLogGroupCommand({ logGroupName }));
}
