import { Router } from 'express';
import {
  listTopics,
  getTopicDetail,
  getTopicPolicy,
  setTopicAttribute,
  listSubscriptions,
  subscribe,
  unsubscribe,
  publish,
  createTopic,
  deleteTopic,
  addTopicTag,
  removeTopicTag,
} from '../../infrastructure/aws/sns.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

const POLICY_ATTRIBUTES = ['Policy', 'DeliveryPolicy'] as const;
const SUBSCRIPTION_PROTOCOLS = ['email', 'email-json', 'http', 'https', 'sqs', 'lambda', 'sms', 'firehose', 'application'];

router.get('/sns/topics', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listTopics(profile, region));
});

router.post('/sns/topics', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, fifo, displayName } = req.body || {};
  if (rejectMissing(res, { name })) return;
  await respond(res, () => createTopic(profile, region, name, Boolean(fifo), displayName));
});

router.get('/sns/topic', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => getTopicDetail(profile, region, arn));
});

router.post('/sns/topic/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn } = req.body || {};
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => deleteTopic(profile, region, arn));
});

router.get('/sns/topic/policy', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  const attribute = (req.query.attribute as string) || 'Policy';
  if (rejectMissing(res, { arn })) return;
  if (!POLICY_ATTRIBUTES.includes(attribute as (typeof POLICY_ATTRIBUTES)[number])) {
    res.status(400).json({ error: 'attribute must be Policy or DeliveryPolicy' });
    return;
  }
  await respond(res, () => getTopicPolicy(profile, region, arn, attribute as (typeof POLICY_ATTRIBUTES)[number]));
});

router.put('/sns/topic/attribute', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, attribute, value } = req.body || {};
  if (rejectMissing(res, { arn, attribute })) return;
  if (!['DisplayName', ...POLICY_ATTRIBUTES].includes(attribute)) {
    res.status(400).json({ error: 'attribute must be DisplayName, Policy or DeliveryPolicy' });
    return;
  }
  await respond(res, () => setTopicAttribute(profile, region, arn, attribute, value ?? ''));
});

router.get('/sns/topic/subscriptions', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const arn = req.query.arn as string;
  if (rejectMissing(res, { arn })) return;
  await respond(res, () => listSubscriptions(profile, region, arn));
});

router.post('/sns/topic/subscriptions', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, protocol, endpoint } = req.body || {};
  if (rejectMissing(res, { arn, protocol, endpoint })) return;
  if (!SUBSCRIPTION_PROTOCOLS.includes(protocol)) {
    res.status(400).json({ error: `protocol must be one of ${SUBSCRIPTION_PROTOCOLS.join(', ')}` });
    return;
  }
  await respond(res, () => subscribe(profile, region, arn, protocol, endpoint));
});

router.post('/sns/subscriptions/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { subscriptionArn } = req.body || {};
  if (rejectMissing(res, { subscriptionArn })) return;
  await respond(res, () => unsubscribe(profile, region, subscriptionArn));
});

router.post('/sns/topic/publish', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, message, subject, messageGroupId, messageDeduplicationId } = req.body || {};
  if (rejectMissing(res, { arn, message })) return;
  await respond(res, () => publish(profile, region, arn, message, subject, messageGroupId, messageDeduplicationId));
});

router.post('/sns/topic/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key, value } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => addTopicTag(profile, region, arn, key, value || ''));
});

router.post('/sns/topic/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { arn, key } = req.body || {};
  if (rejectMissing(res, { arn, key })) return;
  await respond(res, () => removeTopicTag(profile, region, arn, key));
});

export default router;
