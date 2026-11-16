import { Router } from 'express';
import {
  listAlarms,
  getAlarmDetail,
  updateAlarmThreshold,
  setAlarmActionsEnabled,
  deleteAlarm,
  listLogGroups,
  listLogStreams,
  getLogEvents,
  setLogGroupRetention,
  deleteLogGroup,
} from '../../infrastructure/aws/cloudwatch.js';
import { checkMetricRequest, getMetricData } from '../../infrastructure/aws/cloudwatch-metrics.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { profileRegion, respond } from '../middleware/respond.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

/**
 * POST /api/cloudwatch/metric-data { range, queries } - the series of a
 * chart grid in one GetMetricData call (shared MetricChart in the app).
 * Bad input is refused with a 400 before any AWS call.
 */
router.post('/cloudwatch/metric-data', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, async () => {
    const { range, queries } = checkMetricRequest(req.body?.range, req.body?.queries);
    return getMetricData(profile, region, range, queries);
  });
});

// GET /api/cloudwatch/alarms
router.get('/cloudwatch/alarms', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listAlarms(profile, region));
});

// GET /api/cloudwatch/log-groups
router.get('/cloudwatch/log-groups', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listLogGroups(profile, region));
});

router.get('/cloudwatch/alarm', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const alarmName = (req.query.alarmName as string) || '';
    res.json(await getAlarmDetail(profile, region, alarmName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/cloudwatch/alarm/threshold', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { alarmName, threshold, comparisonOperator, evaluationPeriods, period } = req.body || {};
    if (!alarmName || typeof threshold !== 'number' || !comparisonOperator || typeof evaluationPeriods !== 'number' || typeof period !== 'number') {
      res.status(400).json({ error: 'alarmName, threshold, comparisonOperator, evaluationPeriods and period are required' });
      return;
    }
    res.json(await updateAlarmThreshold(profile, region, alarmName, { threshold, comparisonOperator, evaluationPeriods, period }));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/cloudwatch/alarm/actions-enabled', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { alarmName, enabled } = req.body || {};
    if (!alarmName || typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'alarmName and enabled are required' });
      return;
    }
    res.json(await setAlarmActionsEnabled(profile, region, alarmName, enabled));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudwatch/alarm/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { alarmName } = req.body || {};
    if (!alarmName) {
      res.status(400).json({ error: 'alarmName is required' });
      return;
    }
    await deleteAlarm(profile, region, alarmName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudwatch/log-group/streams', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const logGroupName = (req.query.logGroupName as string) || '';
    res.json(await listLogStreams(profile, region, logGroupName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/cloudwatch/log-group/events', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const logGroupName = (req.query.logGroupName as string) || '';
    const logStreamName = (req.query.logStreamName as string) || '';
    res.json(await getLogEvents(profile, region, logGroupName, logStreamName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/cloudwatch/log-group/retention', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { logGroupName, retentionInDays } = req.body || {};
    if (!logGroupName) {
      res.status(400).json({ error: 'logGroupName is required' });
      return;
    }
    await setLogGroupRetention(profile, region, logGroupName, typeof retentionInDays === 'number' ? retentionInDays : null);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/cloudwatch/log-group/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { logGroupName } = req.body || {};
    if (!logGroupName) {
      res.status(400).json({ error: 'logGroupName is required' });
      return;
    }
    await deleteLogGroup(profile, region, logGroupName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
