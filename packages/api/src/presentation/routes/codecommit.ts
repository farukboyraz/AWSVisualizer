import { Router } from 'express';
import {
  listRepositories,
  getRepositoryDetail,
  updateRepositoryName,
  updateRepositoryDescription,
  updateDefaultBranch,
  addRepositoryTag,
  removeRepositoryTag,
  listBranches,
  getFolder,
  getFile,
  getCommits,
  getCommitsForPath,
  getCommit,
  getCommitsAhead,
  getDifferences,
  getFileDiff,
  listPullRequests,
  getPullRequest,
  createPullRequest,
  checkMergeConflicts,
  mergePullRequest,
  closePullRequest,
  PR_TITLE_MAX_LENGTH,
  PR_DESCRIPTION_MAX_LENGTH,
  createBranch,
  deleteBranch,
  createRepository,
  deleteRepository,
  mergeBranches,
  getPullRequestComments,
  postPullRequestComment,
  postCommentReply,
  deletePullRequestComment,
  checkCommentInput,
  getPullRequestApprovals,
  setPullRequestApproval,
  getPullRequestEvents,
  getRepositoryTriggers,
  putRepositoryTriggers,
  testRepositoryTriggers,
  putFile,
  deleteRepositoryFile,
  searchFilePaths,
} from '../../infrastructure/aws/codecommit.js';
import type { CodeCommitMergeOption, CodeCommitRepositoryTrigger } from '../../domain/entities/index.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

const router = Router();

router.get('/codecommit/repositories', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    res.json(await listRepositories(profile, region));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/repository', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    res.json(await getRepositoryDetail(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/codecommit/repository/name', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { oldName, newName } = req.body || {};
    if (!oldName || !newName) {
      res.status(400).json({ error: 'oldName and newName are required' });
      return;
    }
    res.json(await updateRepositoryName(profile, region, oldName, newName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/codecommit/repository/description', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, description } = req.body || {};
    if (!repositoryName) {
      res.status(400).json({ error: 'repositoryName is required' });
      return;
    }
    res.json(await updateRepositoryDescription(profile, region, repositoryName, description || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/codecommit/repository/default-branch', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, defaultBranchName } = req.body || {};
    if (!repositoryName || !defaultBranchName) {
      res.status(400).json({ error: 'repositoryName and defaultBranchName are required' });
      return;
    }
    res.json(await updateDefaultBranch(profile, region, repositoryName, defaultBranchName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/repository/tags', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, key, value } = req.body || {};
    if (!repositoryName || !key) {
      res.status(400).json({ error: 'repositoryName and key are required' });
      return;
    }
    res.json(await addRepositoryTag(profile, region, repositoryName, key, value || ''));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/repository/tags/remove', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, key } = req.body || {};
    if (!repositoryName || !key) {
      res.status(400).json({ error: 'repositoryName and key are required' });
      return;
    }
    res.json(await removeRepositoryTag(profile, region, repositoryName, key));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/branches', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    res.json(await listBranches(profile, region, name));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/folder', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const path = (req.query.path as string) || '/';
    const commit = req.query.commit as string | undefined;
    res.json(await getFolder(profile, region, name, path, commit));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/file', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const path = (req.query.path as string) || '';
    const commit = req.query.commit as string | undefined;
    res.json(await getFile(profile, region, name, path, commit));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/commits', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const commit = (req.query.commit as string) || '';
    const limit = req.query.limit ? Number(req.query.limit) : 30;
    res.json(await getCommits(profile, region, name, commit, limit));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/commits-for-path', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const commit = (req.query.commit as string) || '';
    const path = (req.query.path as string) || '';
    const cursor = (req.query.cursor as string) || undefined;
    const limit = req.query.limit ? Number(req.query.limit) : 30;
    res.json(await getCommitsForPath(profile, region, name, commit, path, cursor, limit));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/commit', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const commit = (req.query.commit as string) || '';
    const result = await getCommit(profile, region, name, commit);
    if (!result) {
      res.status(404).json({ error: 'Commit not found' });
      return;
    }
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/commits-ahead', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const source = (req.query.source as string) || '';
    const destination = (req.query.destination as string) || '';
    res.json(await getCommitsAhead(profile, region, name, source, destination));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/differences', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const before = req.query.before as string | undefined;
    const after = (req.query.after as string) || '';
    res.json(await getDifferences(profile, region, name, before, after));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/file-diff', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const path = (req.query.path as string) || '';
    const before = req.query.before as string | undefined;
    const after = (req.query.after as string) || '';
    res.json(await getFileDiff(profile, region, name, path, before, after, req.query.full === '1'));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/pr-limits', async (_req, res) => {
  res.json({ titleMaxLength: PR_TITLE_MAX_LENGTH, descriptionMaxLength: PR_DESCRIPTION_MAX_LENGTH });
});

router.get('/codecommit/pull-requests', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const status = (req.query.status as string) === 'CLOSED' ? 'CLOSED' : 'OPEN';
    res.json(await listPullRequests(profile, region, name, status));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/pull-requests', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, title, description, sourceReference, destinationReference } = req.body || {};

    if (!repositoryName || !title || !sourceReference || !destinationReference) {
      res.status(400).json({ error: 'repositoryName, title, sourceReference and destinationReference are required' });
      return;
    }

    const pr = await createPullRequest(profile, region, {
      repositoryName,
      title,
      description,
      sourceReference,
      destinationReference,
    });
    res.json(pr);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/pull-request', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const id = (req.query.id as string) || '';
    const result = await getPullRequest(profile, region, id);
    if (!result) {
      res.status(404).json({ error: 'Pull request not found' });
      return;
    }
    res.json(result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.get('/codecommit/merge-conflicts', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const name = (req.query.name as string) || '';
    const destination = (req.query.destination as string) || '';
    const source = (req.query.source as string) || '';
    const mergeOption = (req.query.mergeOption as CodeCommitMergeOption) || 'FAST_FORWARD_MERGE';
    res.json(await checkMergeConflicts(profile, region, name, destination, source, mergeOption));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/pull-requests/merge', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, pullRequestId, mergeOption, commitMessage } = req.body || {};

    if (!repositoryName || !pullRequestId || !mergeOption) {
      res.status(400).json({ error: 'repositoryName, pullRequestId and mergeOption are required' });
      return;
    }

    const pr = await mergePullRequest(profile, region, { repositoryName, pullRequestId, mergeOption, commitMessage });
    res.json(pr);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/pull-requests/close', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { pullRequestId } = req.body || {};

    if (!pullRequestId) {
      res.status(400).json({ error: 'pullRequestId is required' });
      return;
    }

    const pr = await closePullRequest(profile, region, pullRequestId);
    res.json(pr);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Branches ---

router.post('/codecommit/branches', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, branchName, commitId } = req.body || {};
    if (!repositoryName || !branchName || !commitId) {
      res.status(400).json({ error: 'repositoryName, branchName and commitId are required' });
      return;
    }
    await createBranch(profile, region, repositoryName, branchName, commitId);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/branches/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, branchName } = req.body || {};
    if (!repositoryName || !branchName) {
      res.status(400).json({ error: 'repositoryName and branchName are required' });
      return;
    }
    await deleteBranch(profile, region, repositoryName, branchName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/branches/merge', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, sourceBranch, destinationBranch, mergeOption, commitMessage } = req.body || {};
    if (!repositoryName || !sourceBranch || !destinationBranch || !mergeOption) {
      res.status(400).json({ error: 'repositoryName, sourceBranch, destinationBranch and mergeOption are required' });
      return;
    }
    await mergeBranches(profile, region, { repositoryName, sourceBranch, destinationBranch, mergeOption, commitMessage });
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Repositories ---

router.post('/codecommit/repositories', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, description } = req.body || {};
    if (!repositoryName) {
      res.status(400).json({ error: 'repositoryName is required' });
      return;
    }
    await createRepository(profile, region, repositoryName, description);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/repositories/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName } = req.body || {};
    if (!repositoryName) {
      res.status(400).json({ error: 'repositoryName is required' });
      return;
    }
    await deleteRepository(profile, region, repositoryName);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Pull request comments ---

router.get('/codecommit/pull-requests/comments', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const pullRequestId = (req.query.pullRequestId as string) || '';
    const repositoryName = req.query.repositoryName as string | undefined;
    const beforeCommitId = req.query.beforeCommitId as string | undefined;
    const afterCommitId = req.query.afterCommitId as string | undefined;
    res.json(await getPullRequestComments(profile, region, pullRequestId, repositoryName, beforeCommitId, afterCommitId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/pull-requests/comments', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { pullRequestId, repositoryName, beforeCommitId, afterCommitId, content, filePath, filePosition, relativeFileVersion } = req.body || {};
    if (!pullRequestId || !repositoryName || !beforeCommitId || !afterCommitId || !content) {
      res.status(400).json({ error: 'pullRequestId, repositoryName, beforeCommitId, afterCommitId and content are required' });
      return;
    }
    checkCommentInput({ content, filePath, filePosition, relativeFileVersion });
    res.json(
      await postPullRequestComment(profile, region, {
        pullRequestId,
        repositoryName,
        beforeCommitId,
        afterCommitId,
        content: content.trim(),
        filePath: filePath || undefined,
        filePosition: typeof filePosition === 'number' ? filePosition : undefined,
        relativeFileVersion: relativeFileVersion || undefined,
      })
    );
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/comments/reply', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { inReplyTo, content } = req.body || {};
    if (!inReplyTo || !content) {
      res.status(400).json({ error: 'inReplyTo and content are required' });
      return;
    }
    checkCommentInput({ content });
    res.json(await postCommentReply(profile, region, inReplyTo, content.trim()));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/comments/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { commentId } = req.body || {};
    if (!commentId) {
      res.status(400).json({ error: 'commentId is required' });
      return;
    }
    await deletePullRequestComment(profile, region, commentId);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Pull request approvals ---

router.get('/codecommit/pull-requests/approvals', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const pullRequestId = (req.query.pullRequestId as string) || '';
    const revisionId = (req.query.revisionId as string) || '';
    res.json(await getPullRequestApprovals(profile, region, pullRequestId, revisionId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/pull-requests/approvals', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { pullRequestId, revisionId, approved } = req.body || {};
    if (!pullRequestId || !revisionId || typeof approved !== 'boolean') {
      res.status(400).json({ error: 'pullRequestId, revisionId and approved are required' });
      return;
    }
    await setPullRequestApproval(profile, region, pullRequestId, revisionId, approved);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Pull request activity timeline ---

router.get('/codecommit/pull-requests/events', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const pullRequestId = (req.query.pullRequestId as string) || '';
    res.json(await getPullRequestEvents(profile, region, pullRequestId));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Repository triggers ---

router.get('/codecommit/triggers', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const repositoryName = (req.query.repositoryName as string) || '';
    res.json(await getRepositoryTriggers(profile, region, repositoryName));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.put('/codecommit/triggers', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, triggers } = req.body || {};
    if (!repositoryName || !Array.isArray(triggers)) {
      res.status(400).json({ error: 'repositoryName and triggers are required' });
      return;
    }
    await putRepositoryTriggers(profile, region, repositoryName, triggers as CodeCommitRepositoryTrigger[]);
    res.json({ ok: true });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/triggers/test', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, triggers } = req.body || {};
    if (!repositoryName || !Array.isArray(triggers)) {
      res.status(400).json({ error: 'repositoryName and triggers are required' });
      return;
    }
    res.json(await testRepositoryTriggers(profile, region, repositoryName, triggers as CodeCommitRepositoryTrigger[]));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- File edit / direct commit ---

router.put('/codecommit/file', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, branchName, filePath, fileContent, commitMessage, parentCommitId } = req.body || {};
    if (!repositoryName || !branchName || !filePath || fileContent === undefined || !commitMessage) {
      res.status(400).json({ error: 'repositoryName, branchName, filePath, fileContent and commitMessage are required' });
      return;
    }
    const commitId = await putFile(profile, region, { repositoryName, branchName, filePath, fileContent, commitMessage, parentCommitId });
    res.json({ commitId });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

router.post('/codecommit/file/delete', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const { repositoryName, branchName, filePath, commitMessage, parentCommitId } = req.body || {};
    if (!repositoryName || !branchName || !filePath || !commitMessage || !parentCommitId) {
      res.status(400).json({ error: 'repositoryName, branchName, filePath, commitMessage and parentCommitId are required' });
      return;
    }
    const commitId = await deleteRepositoryFile(profile, region, repositoryName, branchName, filePath, commitMessage, parentCommitId);
    res.json({ commitId });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

// --- Quick file switcher ---

router.get('/codecommit/files/search', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const repositoryName = (req.query.repositoryName as string) || '';
    const commitSpecifier = (req.query.commitSpecifier as string) || '';
    const query = (req.query.q as string) || '';
    const cursor = (req.query.cursor as string) || undefined;
    const limit = req.query.limit ? Number(req.query.limit) : 10;
    res.json(await searchFilePaths(profile, region, repositoryName, commitSpecifier, query, cursor, limit));
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
