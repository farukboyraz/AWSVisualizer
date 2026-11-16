import { Router } from 'express';
import {
  listLoadBalancers,
  getLoadBalancerDetail,
  listListeners,
  listTargetGroups,
  setDeletionProtection,
  addLoadBalancerTag,
  removeLoadBalancerTag,
} from '../../infrastructure/aws/elb.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

router.get('/elasticloadbalancing/load-balancers', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listLoadBalancers(profile, region));
});

router.get('/elasticloadbalancing/load-balancer', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => getLoadBalancerDetail(profile, region, arn));
});

router.get('/elasticloadbalancing/load-balancer/listeners', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => listListeners(profile, region, arn));
});

router.get('/elasticloadbalancing/load-balancer/target-groups', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => listTargetGroups(profile, region, arn));
});

router.put('/elasticloadbalancing/load-balancer/deletion-protection', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, enabled } = req.body || {};
  if (rejectMissing(res, { arn, enabled })) return;
  await respond(res, () => setDeletionProtection(profile, region, arn, Boolean(enabled)));
});

router.post('/elasticloadbalancing/load-balancer/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key, value } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => addLoadBalancerTag(profile, region, arn, key, value || ''));
});

router.post('/elasticloadbalancing/load-balancer/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => removeLoadBalancerTag(profile, region, arn, key));
});

export default router;
