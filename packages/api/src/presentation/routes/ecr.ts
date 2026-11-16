import { Router } from 'express';
import {
  listRepositories,
  getRepositoryDetail,
  listImages,
  getScanFindings,
  startImageScan,
  deleteImage,
  getLifecyclePolicy,
  putLifecyclePolicy,
  deleteLifecyclePolicy,
  getRepositoryPolicy,
  setRepositoryPolicy,
  deleteRepositoryPolicy,
  setTagMutability,
  setScanOnPush,
  addRepositoryTag,
  removeRepositoryTag,
} from '../../infrastructure/aws/ecr.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';

const router = Router();

router.get('/ecr/repositories', async (req, res) => {
  const { profile, region } = profileRegion(req);
  await respond(res, () => listRepositories(profile, region));
});

router.get('/ecr/repository', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getRepositoryDetail(profile, region, name));
});

router.get('/ecr/repository/images', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => listImages(profile, region, name, (req.query.nextToken as string) || undefined));
});

router.get('/ecr/repository/image/findings', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  const digest = req.query.digest as string;
  if (rejectMissing(res, { name, digest })) return;
  await respond(res, () => getScanFindings(profile, region, name, digest));
});

router.post('/ecr/repository/image/scan', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, digest } = req.body || {};
  if (rejectMissing(res, { name, digest })) return;
  await respond(res, () => startImageScan(profile, region, name, digest));
});

router.post('/ecr/repository/image/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, digest } = req.body || {};
  if (rejectMissing(res, { name, digest })) return;
  await respond(res, () => deleteImage(profile, region, name, digest));
});

router.get('/ecr/repository/lifecycle-policy', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getLifecyclePolicy(profile, region, name));
});

router.put('/ecr/repository/lifecycle-policy', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, policy } = req.body || {};
  if (rejectMissing(res, { name, policy })) return;
  await respond(res, () => putLifecyclePolicy(profile, region, name, policy));
});

router.post('/ecr/repository/lifecycle-policy/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name } = req.body || {};
  if (rejectMissing(res, { name })) return;
  await respond(res, () => deleteLifecyclePolicy(profile, region, name));
});

router.get('/ecr/repository/policy', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const name = req.query.name as string;
  if (rejectMissing(res, { name })) return;
  await respond(res, () => getRepositoryPolicy(profile, region, name));
});

router.put('/ecr/repository/policy', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, policy } = req.body || {};
  if (rejectMissing(res, { name, policy })) return;
  await respond(res, () => setRepositoryPolicy(profile, region, name, policy));
});

router.post('/ecr/repository/policy/delete', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name } = req.body || {};
  if (rejectMissing(res, { name })) return;
  await respond(res, () => deleteRepositoryPolicy(profile, region, name));
});

router.put('/ecr/repository/tag-mutability', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, mutability } = req.body || {};
  if (rejectMissing(res, { name, mutability })) return;
  if (mutability !== 'MUTABLE' && mutability !== 'IMMUTABLE') {
    res.status(400).json({ error: 'mutability must be MUTABLE or IMMUTABLE' });
    return;
  }
  await respond(res, () => setTagMutability(profile, region, name, mutability));
});

router.put('/ecr/repository/scan-on-push', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, enabled } = req.body || {};
  if (rejectMissing(res, { name, enabled })) return;
  await respond(res, () => setScanOnPush(profile, region, name, Boolean(enabled)));
});

router.post('/ecr/repository/tags', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, arn, key, value } = req.body || {};
  if (rejectMissing(res, { name, arn, key })) return;
  await respond(res, () => addRepositoryTag(profile, region, name, arn, key, value || ''));
});

router.post('/ecr/repository/tags/remove', async (req, res) => {
  const { profile, region } = profileRegion(req);
  const { name, arn, key } = req.body || {};
  if (rejectMissing(res, { name, arn, key })) return;
  await respond(res, () => removeRepositoryTag(profile, region, name, arn, key));
});

export default router;
