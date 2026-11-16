import { Router } from 'express';
import {
  getWorkspaceStatus,
  cloneWorkspace,
  matchWorkspace,
  listAllWorkspaces,
  pullWorkspace,
  pushWorkspace,
  mergeBranchIntoWorkspace,
  forgetWorkspace,
  getLocalDiffSummary,
  getLocalFileDiff,
} from '../../infrastructure/local-git.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

router.get('/workspace/list', (_req, res) => {
  res.json(listAllWorkspaces());
});

router.get('/workspace/status', async (req, res) => {
  try {
    const name = (req.query.name as string) || '';
    res.json(await getWorkspaceStatus(name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/workspace/match', async (req, res) => {
  try {
    const { name, cloneUrl, localPath } = req.body || {};
    if (!name || !localPath) {
      res.status(400).json({ error: 'name and localPath are required' });
      return;
    }
    res.json(await matchWorkspace(name, cloneUrl, localPath));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/workspace/clone', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const { name, cloneUrl, parentDirectory } = req.body || {};
    if (!name || !cloneUrl || !parentDirectory) {
      res.status(400).json({ error: 'name, cloneUrl and parentDirectory are required' });
      return;
    }
    res.json(await cloneWorkspace(profile, name, cloneUrl, parentDirectory));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/workspace/pull', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    res.json(await pullWorkspace(profile, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/workspace/push', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    res.json(await pushWorkspace(profile, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/workspace/merge', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const { name, branch } = req.body || {};
    if (!name || !branch) {
      res.status(400).json({ error: 'name and branch are required' });
      return;
    }
    res.json(await mergeBranchIntoWorkspace(profile, name, branch));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/workspace/diff/summary', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const name = (req.query.name as string) || '';
    const branch = (req.query.branch as string) || '';
    if (!name || !branch) {
      res.status(400).json({ error: 'name and branch are required' });
      return;
    }
    res.json(await getLocalDiffSummary(profile, name, branch));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/workspace/diff/file', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const name = (req.query.name as string) || '';
    const branch = (req.query.branch as string) || '';
    const path = (req.query.path as string) || '';
    if (!name || !branch || !path) {
      res.status(400).json({ error: 'name, branch and path are required' });
      return;
    }
    res.json(await getLocalFileDiff(profile, name, branch, path, req.query.full === '1'));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/workspace/forget', async (req, res) => {
  try {
    const { name } = req.body || {};
    if (!name) {
      res.status(400).json({ error: 'name is required' });
      return;
    }
    forgetWorkspace(name);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
