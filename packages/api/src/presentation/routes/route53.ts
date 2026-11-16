import { Router } from 'express';
import {
  listHostedZones,
  getZoneDetail,
  listRecords,
  createRecord,
  updateRecord,
  deleteRecord,
  updateZoneComment,
  addZoneTag,
  removeZoneTag,
} from '../../infrastructure/aws/route53.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

// GET /api/route53/zones
router.get('/route53/zones', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listHostedZones(profile, region));
});

router.get('/route53/zone', async (req, res) => {
  const { profile } = profileRegion(req);
  const zoneId = req.query.zoneId as string;
  if (rejectMissing(res, { zoneId })) return;
  await respond(res, () => getZoneDetail(profile, zoneId));
});

router.get('/route53/zone/records', async (req, res) => {
  const { profile } = profileRegion(req);
  const zoneId = req.query.zoneId as string;
  if (rejectMissing(res, { zoneId })) return;
  await respond(res, () =>
    listRecords(profile, zoneId, {
      name: (req.query.startName as string) || undefined,
      type: (req.query.startType as string) || undefined,
      identifier: (req.query.startIdentifier as string) || undefined,
    })
  );
});

function validValues(values: unknown): values is string[] {
  return Array.isArray(values) && values.length > 0 && values.every((v) => typeof v === 'string' && v.trim() !== '');
}

router.post('/route53/zone/records', async (req, res) => {
  const { profile } = profileRegion(req);
  const { zoneId, name, type, ttl, values } = req.body || {};
  if (rejectMissing(res, { zoneId, name, type, ttl })) return;
  if (!validValues(values)) {
    res.status(400).json({ error: 'values must be a non-empty list' });
    return;
  }
  await respond(res, () => createRecord(profile, zoneId, name, type, ttl, values));
});

router.put('/route53/zone/records', async (req, res) => {
  const { profile } = profileRegion(req);
  const { zoneId, name, type, setIdentifier, ttl, values } = req.body || {};
  if (rejectMissing(res, { zoneId, name, type, ttl })) return;
  if (!validValues(values)) {
    res.status(400).json({ error: 'values must be a non-empty list' });
    return;
  }
  await respond(res, () => updateRecord(profile, zoneId, name, type, setIdentifier || undefined, ttl, values));
});

router.post('/route53/zone/records/delete', async (req, res) => {
  const { profile } = profileRegion(req);
  const { zoneId, name, type, setIdentifier } = req.body || {};
  if (rejectMissing(res, { zoneId, name, type })) return;
  await respond(res, () => deleteRecord(profile, zoneId, name, type, setIdentifier || undefined));
});

router.put('/route53/zone/comment', async (req, res) => {
  const { profile } = profileRegion(req);
  const { zoneId, comment } = req.body || {};
  if (rejectMissing(res, { zoneId })) return;
  await respond(res, () => updateZoneComment(profile, zoneId, comment || ''));
});

router.post('/route53/zone/tags', async (req, res) => {
  const { profile } = profileRegion(req);
  const { zoneId, key, value } = req.body || {};
  if (rejectMissing(res, { zoneId, key })) return;
  await respond(res, () => addZoneTag(profile, zoneId, key, value || ''));
});

router.post('/route53/zone/tags/remove', async (req, res) => {
  const { profile } = profileRegion(req);
  const { zoneId, key } = req.body || {};
  if (rejectMissing(res, { zoneId, key })) return;
  await respond(res, () => removeZoneTag(profile, zoneId, key));
});

export default router;
