import { Router } from 'express';
import {
  listQueues,
  getQueueDetail,
  updateQueueAttributes,
  sendMessage,
  receiveMessages,
  deleteMessage,
  addQueueTag,
  removeQueueTag,
  purgeQueue,
} from '../../infrastructure/aws/sqs.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

// GET /api/sqs/queues
router.get('/sqs/queues', async (req, res) => {
  const profile = req.query.profile as string;
  const region = req.query.region as string;

  if (!profile || !region) {
    res.status(400).json({ error: 'profile and region parameters are required' });
    return;
  }

  await withAuthGuard(res, () => listQueues(profile, region));
});

router.get('/sqs/queue', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const queueUrl = (req.query.queueUrl as string) || '';
    res.json(await getQueueDetail(profile, region, queueUrl));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/sqs/queue/attributes', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl, attributes } = req.body || {};
    if (!queueUrl || !attributes) {
      res.status(400).json({ error: 'queueUrl and attributes are required' });
      return;
    }
    res.json(await updateQueueAttributes(profile, region, queueUrl, attributes));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/sqs/queue/purge', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl } = req.body || {};
    if (!queueUrl) {
      res.status(400).json({ error: 'queueUrl is required' });
      return;
    }
    res.json(await purgeQueue(profile, region, queueUrl));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/sqs/messages/send', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl, body, delaySeconds, messageGroupId, messageDeduplicationId } = req.body || {};
    if (!queueUrl || !body) {
      res.status(400).json({ error: 'queueUrl and body are required' });
      return;
    }
    const messageId = await sendMessage(profile, region, queueUrl, body, delaySeconds, messageGroupId, messageDeduplicationId);
    res.json({ messageId });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/sqs/messages/receive', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl, maxMessages } = req.body || {};
    if (!queueUrl) {
      res.status(400).json({ error: 'queueUrl is required' });
      return;
    }
    res.json(await receiveMessages(profile, region, queueUrl, maxMessages));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/sqs/messages/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl, receiptHandle } = req.body || {};
    if (!queueUrl || !receiptHandle) {
      res.status(400).json({ error: 'queueUrl and receiptHandle are required' });
      return;
    }
    await deleteMessage(profile, region, queueUrl, receiptHandle);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/sqs/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl, key, value } = req.body || {};
    if (!queueUrl || !key) {
      res.status(400).json({ error: 'queueUrl and key are required' });
      return;
    }
    res.json(await addQueueTag(profile, region, queueUrl, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/sqs/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { queueUrl, key } = req.body || {};
    if (!queueUrl || !key) {
      res.status(400).json({ error: 'queueUrl and key are required' });
      return;
    }
    res.json(await removeQueueTag(profile, region, queueUrl, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
