import {
  CodeCommitClient,
  ListRepositoriesCommand,
  GetRepositoryCommand,
  ListBranchesCommand,
  GetBranchCommand,
  GetFolderCommand,
  GetFileCommand,
  GetCommitCommand,
  BatchGetCommitsCommand,
  GetDifferencesCommand,
  GetBlobCommand,
  ListPullRequestsCommand,
  GetPullRequestCommand,
  CreatePullRequestCommand,
  GetMergeConflictsCommand,
  MergePullRequestByFastForwardCommand,
  MergePullRequestBySquashCommand,
  MergePullRequestByThreeWayCommand,
  UpdatePullRequestStatusCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  UpdateRepositoryNameCommand,
  UpdateRepositoryDescriptionCommand,
  UpdateDefaultBranchCommand,
  PullRequestStatusEnum,
  CreateBranchCommand,
  DeleteBranchCommand,
  CreateRepositoryCommand,
  DeleteRepositoryCommand,
  MergeBranchesByFastForwardCommand,
  MergeBranchesBySquashCommand,
  MergeBranchesByThreeWayCommand,
  PostCommentForPullRequestCommand,
  PostCommentReplyCommand,
  GetCommentsForPullRequestCommand,
  DeleteCommentContentCommand,
  GetPullRequestApprovalStatesCommand,
  UpdatePullRequestApprovalStateCommand,
  DescribePullRequestEventsCommand,
  GetRepositoryTriggersCommand,
  PutRepositoryTriggersCommand,
  TestRepositoryTriggersCommand,
  PutFileCommand,
  DeleteFileCommand,
  type Commit,
  type Difference,
  type PullRequest,
  type ConflictMetadata,
  type RepositoryTriggerEventEnum,
} from '@aws-sdk/client-codecommit';
import { cachedCredentials } from './credential-cache.js';
import { t, CardInputError } from '../dashboard-cards/types.js';
import { imageMimeType } from '../archive.js';
import { buildFileDiff } from '../diff-utils.js';
import type {
  CodeCommitRepository,
  CodeCommitRepositoryDetail,
  CodeCommitTag,
  CodeCommitBranch,
  CodeCommitFolderListing,
  CodeCommitFileContent,
  CodeCommitCommit,
  CodeCommitPullRequest,
  CodeCommitMergeOption,
  CodeCommitMergeCheck,
  CodeCommitDiffEntry,
  CodeCommitFileDiff,
  CodeCommitComment,
  CodeCommitCommentThread,
  CodeCommitApproval,
  CodeCommitPullRequestEvent,
  CodeCommitRepositoryTrigger,
} from '../../domain/entities/index.js';

// Matches AWS CodeCommit's own CreatePullRequestInput constraints, so the
// client-side counter/limit in the "New Pull Request" form always agrees
// with what the API will actually accept.
export const PR_TITLE_MAX_LENGTH = 100;
export const PR_DESCRIPTION_MAX_LENGTH = 10240;

function createClient(profile: string, region: string): CodeCommitClient {
  return new CodeCommitClient({ region, credentials: cachedCredentials(profile) });
}

export async function listRepositories(profile: string, region: string): Promise<CodeCommitRepository[]> {
  const client = createClient(profile, region);
  const response = await client.send(new ListRepositoriesCommand({}));

  return (response.repositories || []).map((r) => ({
    repositoryName: r.repositoryName || '',
    repositoryId: r.repositoryId || '',
  }));
}

export async function getRepositoryDetail(
  profile: string,
  region: string,
  repositoryName: string
): Promise<CodeCommitRepositoryDetail> {
  const client = createClient(profile, region);
  const response = await client.send(new GetRepositoryCommand({ repositoryName }));
  const repo = response.repositoryMetadata || {};

  let tags: CodeCommitTag[] = [];
  if (repo.Arn) {
    try {
      const tagsResponse = await client.send(new ListTagsForResourceCommand({ resourceArn: repo.Arn }));
      tags = Object.entries(tagsResponse.tags || {}).map(([key, value]) => ({ key, value: value || '' }));
    } catch {
      tags = [];
    }
  }

  return {
    repositoryName: repo.repositoryName || repositoryName,
    repositoryId: repo.repositoryId || '',
    description: repo.repositoryDescription,
    defaultBranch: repo.defaultBranch,
    cloneUrlHttp: repo.cloneUrlHttp,
    arn: repo.Arn,
    creationDate: repo.creationDate?.toISOString(),
    lastModifiedDate: repo.lastModifiedDate?.toISOString(),
    tags,
  };
}

export async function updateRepositoryName(profile: string, region: string, oldName: string, newName: string): Promise<CodeCommitRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new UpdateRepositoryNameCommand({ oldName, newName }));
  return getRepositoryDetail(profile, region, newName);
}

export async function updateRepositoryDescription(profile: string, region: string, repositoryName: string, description: string): Promise<CodeCommitRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new UpdateRepositoryDescriptionCommand({ repositoryName, repositoryDescription: description }));
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function updateDefaultBranch(profile: string, region: string, repositoryName: string, defaultBranchName: string): Promise<CodeCommitRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new UpdateDefaultBranchCommand({ repositoryName, defaultBranchName }));
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function addRepositoryTag(profile: string, region: string, repositoryName: string, key: string, value: string): Promise<CodeCommitRepositoryDetail> {
  const client = createClient(profile, region);
  const repo = await client.send(new GetRepositoryCommand({ repositoryName }));
  const arn = repo.repositoryMetadata?.Arn;
  if (arn) {
    await client.send(new TagResourceCommand({ resourceArn: arn, tags: { [key]: value } }));
  }
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function removeRepositoryTag(profile: string, region: string, repositoryName: string, key: string): Promise<CodeCommitRepositoryDetail> {
  const client = createClient(profile, region);
  const repo = await client.send(new GetRepositoryCommand({ repositoryName }));
  const arn = repo.repositoryMetadata?.Arn;
  if (arn) {
    await client.send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  }
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function listBranches(
  profile: string,
  region: string,
  repositoryName: string
): Promise<CodeCommitBranch[]> {
  const client = createClient(profile, region);
  const response = await client.send(new ListBranchesCommand({ repositoryName }));
  const names = response.branches || [];

  return Promise.all(
    names.map(async (name) => {
      try {
        const branch = await client.send(new GetBranchCommand({ repositoryName, branchName: name }));
        return { name, commitId: branch.branch?.commitId };
      } catch {
        return { name };
      }
    })
  );
}

export async function getFolder(
  profile: string,
  region: string,
  repositoryName: string,
  path: string,
  commitSpecifier?: string
): Promise<CodeCommitFolderListing> {
  const client = createClient(profile, region);
  const folderPath = path || '/';
  const response = await client.send(
    new GetFolderCommand({ repositoryName, folderPath, commitSpecifier })
  );

  const entries = [
    ...(response.subFolders || []).map((f) => ({
      name: f.relativePath || '',
      path: f.absolutePath || '',
      isFolder: true,
    })),
    ...(response.files || []).map((f) => ({
      name: f.relativePath || '',
      path: f.absolutePath || '',
      isFolder: false,
    })),
  ].sort((a, b) => (a.isFolder === b.isFolder ? a.name.localeCompare(b.name) : a.isFolder ? -1 : 1));

  return {
    path: response.folderPath || folderPath,
    commitId: response.commitId || '',
    entries,
  };
}

const MAX_FILE_PREVIEW_SIZE = 1024 * 1024; // 1MB

/**
 * Sniffs actual bytes rather than trusting the file extension - a repo has
 * far more genuinely-text files (Dockerfile, LICENSE, .tf, .gitignore, .kt,
 * .c, ...) than any fixed extension whitelist can enumerate, and treating
 * all of those as "binary" was why most files silently failed to preview.
 * Same heuristic git/GitHub use: a NUL byte anywhere in the first few KB
 * means binary.
 */
function isLikelyBinaryContent(bytes: Uint8Array): boolean {
  const sampleLength = Math.min(bytes.length, 8000);
  for (let i = 0; i < sampleLength; i++) {
    if (bytes[i] === 0) return true;
  }
  return false;
}

const MAX_IMAGE_PREVIEW_SIZE = 10 * 1024 * 1024;

export async function getFile(
  profile: string,
  region: string,
  repositoryName: string,
  path: string,
  commitSpecifier?: string
): Promise<CodeCommitFileContent> {
  const client = createClient(profile, region);
  const response = await client.send(
    new GetFileCommand({ repositoryName, filePath: path, commitSpecifier })
  );

  const size = response.fileSize || 0;
  const bytes = response.fileContent;
  const isText = size <= MAX_FILE_PREVIEW_SIZE && !!bytes && !isLikelyBinaryContent(bytes);
  let content: string | undefined;

  if (isText && bytes) {
    content = Buffer.from(bytes).toString('utf-8');
  }

  // Images come back as base64 so the preview can show them.
  const mimeType = imageMimeType(path);
  const imageBase64 = !isText && mimeType && bytes && size <= MAX_IMAGE_PREVIEW_SIZE ? Buffer.from(bytes).toString('base64') : undefined;

  return {
    path: response.filePath || path,
    commitId: response.commitId || '',
    size,
    isText,
    content,
    imageBase64,
    mimeType: imageBase64 ? mimeType : undefined,
  };
}

async function fetchCommit(
  client: CodeCommitClient,
  repositoryName: string,
  commitId: string
): Promise<Commit | undefined> {
  const response = await client.send(new GetCommitCommand({ repositoryName, commitId }));
  return response.commit;
}

function mapCommit(commit: Commit): CodeCommitCommit {
  const commitId = commit.commitId || '';
  return {
    commitId,
    shortId: commitId.slice(0, 8),
    message: commit.message || '',
    authorName: commit.author?.name,
    authorEmail: commit.author?.email,
    date: commit.author?.date,
    parents: commit.parents || [],
  };
}

/**
 * GetCommit needs a real commit SHA, but GetFolder/GetFile happily accept a
 * branch name as a "commit specifier". Resolve branch names to their tip
 * commit ID first so callers can pass either.
 */
async function resolveCommitId(client: CodeCommitClient, repositoryName: string, ref: string): Promise<string> {
  if (/^[0-9a-f]{40}$/i.test(ref)) return ref;
  try {
    const response = await client.send(new GetBranchCommand({ repositoryName, branchName: ref }));
    return response.branch?.commitId || ref;
  } catch {
    return ref;
  }
}

/** Seconds since epoch from CodeCommit's "1700000000 +0300" dates. */
function commitTime(commit: Commit): number {
  return parseInt((commit.committer?.date || commit.author?.date || '0').split(' ')[0], 10) || 0;
}

/** Up to 100 commits per call (BatchGetCommits). */
async function fetchCommits(client: CodeCommitClient, repositoryName: string, ids: string[]): Promise<Commit[]> {
  const result: Commit[] = [];
  for (let i = 0; i < ids.length; i += 100) {
    const response = await client.send(new BatchGetCommitsCommand({ repositoryName, commitIds: ids.slice(i, i + 100) }));
    result.push(...(response.commits || []));
  }
  return result;
}

/**
 * The branch's history like `git log`: every parent is followed (not only
 * the first), newest commit first, so commits that came in through a merge
 * are listed too and the app can draw the real branch / merge graph.
 * Each step takes the newest commit from the frontier and fetches its
 * not-yet-seen parents in one BatchGetCommits call.
 */
export async function getCommits(
  profile: string,
  region: string,
  repositoryName: string,
  commitSpecifier: string,
  limit = 30
): Promise<CodeCommitCommit[]> {
  const client = createClient(profile, region);
  const commits: CodeCommitCommit[] = [];
  const head = await resolveCommitId(client, repositoryName, commitSpecifier);
  const seen = new Set<string>([head]);
  const frontier = new Map<string, Commit>();
  for (const commit of await fetchCommits(client, repositoryName, [head])) {
    if (commit.commitId) frontier.set(commit.commitId, commit);
  }

  while (frontier.size > 0 && commits.length < limit) {
    let next: Commit | undefined;
    for (const commit of frontier.values()) {
      if (!next || commitTime(commit) > commitTime(next)) next = commit;
    }
    if (!next?.commitId) break;
    frontier.delete(next.commitId);
    commits.push(mapCommit(next));

    const newParents = (next.parents || []).filter((p) => !seen.has(p));
    newParents.forEach((p) => seen.add(p));
    if (newParents.length) {
      for (const parent of await fetchCommits(client, repositoryName, newParents)) {
        if (parent.commitId) frontier.set(parent.commitId, parent);
      }
    }
  }

  return commits;
}

// How many commits a single page walks the first-parent chain through.
// Discovering each commit is one sequential GetCommit call (no way around
// that - CodeCommit has no "walk N ancestors" batch API, and each hop's ID
// is only known once the previous one is fetched), so this bounds a page's
// worst-case latency to roughly PATH_HISTORY_PAGE_SIZE round trips instead
// of the old fixed 300 - which, sequentially, took minutes and is exactly
// what was timing out the client. Diffing (the other expensive part, one
// GetDifferences per candidate) happens after the chain is collected, in
// concurrent batches, so it doesn't add to that total serially.
const PATH_HISTORY_PAGE_SIZE = 30;
const PATH_HISTORY_DIFF_CONCURRENCY = 15;

export interface PathHistoryPage {
  commits: CodeCommitCommit[];
  nextCursor: string | null;
}

/**
 * "git log -- <path>" - CodeCommit has no direct API for this, so it walks
 * commit history from `commitSpecifier` (or resumes from `cursor`) and, for
 * each commit examined this page, diffs it against its first parent to see
 * whether `path` was touched. A folder path matches any commit that
 * touched a file under it (including subfolders); a file path matches only
 * commits that touched that exact file. `nextCursor` is the commit ID to
 * resume the walk from on the next page, `null` once history is exhausted.
 */
export async function getCommitsForPath(
  profile: string,
  region: string,
  repositoryName: string,
  commitSpecifier: string,
  path: string,
  cursor: string | undefined,
  limit = 30
): Promise<PathHistoryPage> {
  const client = createClient(profile, region);
  const normalizedPath = path.replace(/^\/+/, '').replace(/\/+$/, '');

  let cursorId: string | undefined = cursor ?? (await resolveCommitId(client, repositoryName, commitSpecifier));
  const candidates: { commit: Commit; parent?: string }[] = [];

  while (cursorId && candidates.length < PATH_HISTORY_PAGE_SIZE) {
    const commit = await fetchCommit(client, repositoryName, cursorId);
    if (!commit || !commit.commitId) {
      cursorId = undefined;
      break;
    }
    const parent = commit.parents?.[0];
    candidates.push({ commit, parent });
    cursorId = parent;
  }

  const touches: boolean[] = [];
  for (let i = 0; i < candidates.length; i += PATH_HISTORY_DIFF_CONCURRENCY) {
    const batch = candidates.slice(i, i + PATH_HISTORY_DIFF_CONCURRENCY);
    const results = await Promise.all(
      batch.map(async ({ commit, parent }) => {
        if (normalizedPath.length === 0) return true;
        try {
          const diffs = await getDifferences(profile, region, repositoryName, parent, commit.commitId!, 2000);
          return diffs.some((d) => d.path === normalizedPath || d.path.startsWith(`${normalizedPath}/`));
        } catch {
          return false;
        }
      })
    );
    touches.push(...results);
  }

  const matches = candidates.filter((_, i) => touches[i]).map(({ commit }) => mapCommit(commit)).slice(0, limit);

  return {
    commits: matches,
    nextCursor: cursorId ?? null,
  };
}

export async function getCommit(
  profile: string,
  region: string,
  repositoryName: string,
  commitSpecifier: string
): Promise<CodeCommitCommit | undefined> {
  const client = createClient(profile, region);
  const commitId = await resolveCommitId(client, repositoryName, commitSpecifier);
  const commit = await fetchCommit(client, repositoryName, commitId);
  return commit ? mapCommit(commit) : undefined;
}

/**
 * Commits reachable from `sourceRef` that aren't reachable from
 * `destinationRef` - i.e. what a pull request from source into destination
 * would actually bring in. Used to prefill the PR title with the real
 * "new" commit instead of guessing from just the source branch tip.
 */
export async function getCommitsAhead(
  profile: string,
  region: string,
  repositoryName: string,
  sourceRef: string,
  destinationRef: string,
  limit = 50
): Promise<CodeCommitCommit[]> {
  const client = createClient(profile, region);
  const sourceId = await resolveCommitId(client, repositoryName, sourceRef);
  const destinationId = await resolveCommitId(client, repositoryName, destinationRef);

  const destinationAncestors = new Set<string>();
  let destinationCursor: string | undefined = destinationId;
  let destinationSteps = 0;
  while (destinationCursor && destinationSteps < 500 && !destinationAncestors.has(destinationCursor)) {
    destinationAncestors.add(destinationCursor);
    const commit = await fetchCommit(client, repositoryName, destinationCursor);
    if (!commit) break;
    destinationCursor = commit.parents?.[0];
    destinationSteps++;
  }

  const ahead: CodeCommitCommit[] = [];
  let cursor: string | undefined = sourceId;
  while (cursor && ahead.length < limit && !destinationAncestors.has(cursor)) {
    const commit = await fetchCommit(client, repositoryName, cursor);
    if (!commit || !commit.commitId) break;
    ahead.push(mapCommit(commit));
    cursor = commit.parents?.[0];
  }

  return ahead;
}

export async function getDifferences(
  profile: string,
  region: string,
  repositoryName: string,
  beforeCommitSpecifier: string | undefined,
  afterCommitSpecifier: string,
  limit = 500
): Promise<CodeCommitDiffEntry[]> {
  const client = createClient(profile, region);
  const entries: CodeCommitDiffEntry[] = [];
  let nextToken: string | undefined;

  do {
    const response: { differences?: Difference[]; NextToken?: string } = await client.send(
      new GetDifferencesCommand({
        repositoryName,
        beforeCommitSpecifier,
        afterCommitSpecifier,
        NextToken: nextToken,
      })
    );

    for (const diff of response.differences || []) {
      entries.push({
        changeType: (diff.changeType as 'A' | 'M' | 'D') || 'M',
        path: diff.afterBlob?.path || diff.beforeBlob?.path || '',
        beforeBlobId: diff.beforeBlob?.blobId,
        afterBlobId: diff.afterBlob?.blobId,
      });
    }

    nextToken = response.NextToken;
  } while (nextToken && entries.length < limit);

  return entries;
}

const MAX_DIFF_BLOB_SIZE = 512 * 1024; // 512KB per side - keep the diff computation snappy

async function fetchBlob(client: CodeCommitClient, repositoryName: string, blobId: string | undefined): Promise<Uint8Array | undefined> {
  if (!blobId) return undefined;
  const response = await client.send(new GetBlobCommand({ repositoryName, blobId }));
  return response.content;
}

export async function getFileDiff(
  profile: string,
  region: string,
  repositoryName: string,
  path: string,
  beforeCommitSpecifier: string | undefined,
  afterCommitSpecifier: string,
  fullFile = false
): Promise<CodeCommitFileDiff> {
  const client = createClient(profile, region);
  const differences = await getDifferences(profile, region, repositoryName, beforeCommitSpecifier, afterCommitSpecifier, 5000);
  const entry = differences.find((d) => d.path === path);

  if (!entry) {
    return { path, changeType: 'M', binary: false, additions: 0, deletions: 0, hunks: [] };
  }

  const [beforeBytes, afterBytes] = await Promise.all([
    fetchBlob(client, repositoryName, entry.beforeBlobId),
    fetchBlob(client, repositoryName, entry.afterBlobId),
  ]);

  const sample = afterBytes ?? beforeBytes;
  const tooLarge = (beforeBytes && beforeBytes.byteLength > MAX_DIFF_BLOB_SIZE) || (afterBytes && afterBytes.byteLength > MAX_DIFF_BLOB_SIZE);
  if (tooLarge || (sample && isLikelyBinaryContent(sample))) {
    return { path, changeType: entry.changeType, binary: true, additions: 0, deletions: 0, hunks: [] };
  }

  const beforeText = beforeBytes ? Buffer.from(beforeBytes).toString('utf-8') : '';
  const afterText = afterBytes ? Buffer.from(afterBytes).toString('utf-8') : '';

  return buildFileDiff(path, entry.changeType, beforeText, afterText, fullFile);
}

function mapPullRequest(pr: PullRequest, fallbackId?: string, fallbackStatus?: string): CodeCommitPullRequest {
  const target = pr.pullRequestTargets?.[0];
  return {
    pullRequestId: pr.pullRequestId || fallbackId || '',
    title: pr.title || '',
    description: pr.description,
    status: pr.pullRequestStatus || fallbackStatus || 'OPEN',
    authorArn: pr.authorArn,
    creationDate: pr.creationDate?.toISOString(),
    lastActivityDate: pr.lastActivityDate?.toISOString(),
    sourceReference: target?.sourceReference,
    destinationReference: target?.destinationReference,
    sourceCommit: target?.sourceCommit,
    destinationCommit: target?.destinationCommit,
    mergeBase: target?.mergeBase,
    isMerged: target?.mergeMetadata?.isMerged,
    mergedBy: target?.mergeMetadata?.mergedBy,
    mergeCommitId: target?.mergeMetadata?.mergeCommitId,
    revisionId: pr.revisionId,
  };
}

export async function listPullRequests(
  profile: string,
  region: string,
  repositoryName: string,
  status: 'OPEN' | 'CLOSED' = 'OPEN'
): Promise<CodeCommitPullRequest[]> {
  const client = createClient(profile, region);
  const response = await client.send(
    new ListPullRequestsCommand({
      repositoryName,
      pullRequestStatus: status as PullRequestStatusEnum,
    })
  );
  const ids = response.pullRequestIds || [];

  const results = await Promise.all(
    ids.map(async (id) => {
      try {
        const detail = await client.send(new GetPullRequestCommand({ pullRequestId: id }));
        if (!detail.pullRequest) return null;
        return mapPullRequest(detail.pullRequest, id, status);
      } catch {
        return null;
      }
    })
  );

  return results.filter((r): r is NonNullable<typeof r> => r !== null);
}

export async function getPullRequest(profile: string, region: string, pullRequestId: string): Promise<CodeCommitPullRequest | undefined> {
  const client = createClient(profile, region);
  const response = await client.send(new GetPullRequestCommand({ pullRequestId }));
  return response.pullRequest ? mapPullRequest(response.pullRequest, pullRequestId) : undefined;
}

// AWS only allows OPEN->OPEN, OPEN->CLOSED, or CLOSED->CLOSED - there's no
// "reopen a closed PR" and no true delete, this is the console's "Close
// pull request" action.
export async function closePullRequest(profile: string, region: string, pullRequestId: string): Promise<CodeCommitPullRequest> {
  const client = createClient(profile, region);
  const response = await client.send(
    new UpdatePullRequestStatusCommand({ pullRequestId, pullRequestStatus: 'CLOSED' as PullRequestStatusEnum })
  );
  return response.pullRequest ? mapPullRequest(response.pullRequest, pullRequestId, 'CLOSED') : mapPullRequest({ pullRequestId, pullRequestStatus: 'CLOSED' } as PullRequest);
}

export interface CreatePullRequestParams {
  repositoryName: string;
  title: string;
  description?: string;
  sourceReference: string;
  destinationReference: string;
}

export async function createPullRequest(
  profile: string,
  region: string,
  params: CreatePullRequestParams
): Promise<CodeCommitPullRequest> {
  const client = createClient(profile, region);
  const response = await client.send(
    new CreatePullRequestCommand({
      title: params.title.slice(0, PR_TITLE_MAX_LENGTH),
      description: params.description?.slice(0, PR_DESCRIPTION_MAX_LENGTH),
      targets: [
        {
          repositoryName: params.repositoryName,
          sourceReference: params.sourceReference,
          destinationReference: params.destinationReference,
        },
      ],
    })
  );

  return response.pullRequest ? mapPullRequest(response.pullRequest) : mapPullRequest({ title: params.title } as PullRequest);
}

const MAX_CONFLICT_FILES = 200;

/**
 * Checks whether a pull request can actually be merged with the given
 * strategy before we let the user click the merge button - mirrors the
 * AWS console, which runs this same check and blocks the merge UI when
 * there are conflicts instead of surprising the user with a failed API call.
 */
export async function checkMergeConflicts(
  profile: string,
  region: string,
  repositoryName: string,
  destinationCommitSpecifier: string,
  sourceCommitSpecifier: string,
  mergeOption: CodeCommitMergeOption
): Promise<CodeCommitMergeCheck> {
  const client = createClient(profile, region);
  const conflictedFilePaths: string[] = [];
  let nextToken: string | undefined;
  let mergeable = true;
  let destinationCommitId = destinationCommitSpecifier;
  let sourceCommitId = sourceCommitSpecifier;

  do {
    const response: {
      mergeable?: boolean;
      destinationCommitId?: string;
      sourceCommitId?: string;
      conflictMetadataList?: ConflictMetadata[];
      nextToken?: string;
    } = await client.send(
      new GetMergeConflictsCommand({
        repositoryName,
        destinationCommitSpecifier,
        sourceCommitSpecifier,
        mergeOption,
        nextToken,
      })
    );

    mergeable = response.mergeable ?? mergeable;
    destinationCommitId = response.destinationCommitId || destinationCommitId;
    sourceCommitId = response.sourceCommitId || sourceCommitId;
    for (const conflict of response.conflictMetadataList || []) {
      if (conflict.filePath) conflictedFilePaths.push(conflict.filePath);
    }

    nextToken = response.nextToken;
  } while (nextToken && conflictedFilePaths.length < MAX_CONFLICT_FILES);

  return { mergeable, destinationCommitId, sourceCommitId, conflictedFilePaths };
}

export interface MergePullRequestParams {
  repositoryName: string;
  pullRequestId: string;
  mergeOption: CodeCommitMergeOption;
  commitMessage?: string;
}

export async function mergePullRequest(profile: string, region: string, params: MergePullRequestParams): Promise<CodeCommitPullRequest> {
  const client = createClient(profile, region);
  const { repositoryName, pullRequestId, mergeOption, commitMessage } = params;

  const response = await (() => {
    switch (mergeOption) {
      case 'FAST_FORWARD_MERGE':
        return client.send(new MergePullRequestByFastForwardCommand({ repositoryName, pullRequestId }));
      case 'SQUASH_MERGE':
        return client.send(new MergePullRequestBySquashCommand({ repositoryName, pullRequestId, commitMessage }));
      case 'THREE_WAY_MERGE':
        return client.send(new MergePullRequestByThreeWayCommand({ repositoryName, pullRequestId, commitMessage }));
    }
  })();

  return response.pullRequest ? mapPullRequest(response.pullRequest, pullRequestId, 'CLOSED') : mapPullRequest({ pullRequestId, pullRequestStatus: 'CLOSED' } as PullRequest);
}

// MARK: - Branch create/delete

export async function createBranch(profile: string, region: string, repositoryName: string, branchName: string, commitId: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new CreateBranchCommand({ repositoryName, branchName, commitId }));
}

export async function deleteBranch(profile: string, region: string, repositoryName: string, branchName: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteBranchCommand({ repositoryName, branchName }));
}

// MARK: - Repository create/delete

export async function createRepository(profile: string, region: string, repositoryName: string, description?: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new CreateRepositoryCommand({ repositoryName, repositoryDescription: description || undefined }));
}

export async function deleteRepository(profile: string, region: string, repositoryName: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteRepositoryCommand({ repositoryName }));
}

// MARK: - Direct branch-to-branch merge (outside a pull request)

export interface MergeBranchesParams {
  repositoryName: string;
  sourceBranch: string;
  destinationBranch: string;
  mergeOption: CodeCommitMergeOption;
  commitMessage?: string;
}

export async function mergeBranches(profile: string, region: string, params: MergeBranchesParams): Promise<void> {
  const client = createClient(profile, region);
  const { repositoryName, sourceBranch, destinationBranch, mergeOption, commitMessage } = params;
  const base = { repositoryName, sourceCommitSpecifier: sourceBranch, destinationCommitSpecifier: destinationBranch, targetBranch: destinationBranch };

  switch (mergeOption) {
    case 'FAST_FORWARD_MERGE':
      await client.send(new MergeBranchesByFastForwardCommand(base));
      break;
    case 'SQUASH_MERGE':
      await client.send(new MergeBranchesBySquashCommand({ ...base, commitMessage }));
      break;
    case 'THREE_WAY_MERGE':
      await client.send(new MergeBranchesByThreeWayCommand({ ...base, commitMessage }));
      break;
  }
}

// MARK: - Pull request comments (general + inline diff comments)

function mapCommentThread(entry: {
  location?: { filePath?: string; filePosition?: number; relativeFileVersion?: string };
  beforeCommitId?: string;
  afterCommitId?: string;
  comments?: unknown[];
}): CodeCommitCommentThread {
  const comments = (entry.comments || []) as Array<{
    commentId?: string;
    content?: string;
    inReplyTo?: string;
    creationDate?: Date;
    authorArn?: string;
    deleted?: boolean;
  }>;
  return {
    location: entry.location
      ? { filePath: entry.location.filePath, filePosition: entry.location.filePosition, relativeFileVersion: entry.location.relativeFileVersion }
      : undefined,
    beforeCommitId: entry.beforeCommitId,
    afterCommitId: entry.afterCommitId,
    comments: comments.map((c) => ({
      commentId: c.commentId || '',
      content: c.content || '',
      inReplyTo: c.inReplyTo,
      creationDate: c.creationDate?.toISOString(),
      authorArn: c.authorArn,
      deleted: c.deleted,
    })),
  };
}

export async function getPullRequestComments(
  profile: string,
  region: string,
  pullRequestId: string,
  repositoryName?: string,
  beforeCommitId?: string,
  afterCommitId?: string
): Promise<CodeCommitCommentThread[]> {
  const client = createClient(profile, region);
  // Without commit ids AWS returns every revision's threads (the diff view
  // uses that to tell current from outdated line comments). Paged; capped
  // so a runaway PR can't stall the sidecar.
  const threads: CodeCommitCommentThread[] = [];
  let nextToken: string | undefined;
  do {
    const response = await client.send(
      new GetCommentsForPullRequestCommand({ pullRequestId, repositoryName, beforeCommitId, afterCommitId, maxResults: 100, nextToken })
    );
    threads.push(...(response.commentsForPullRequestData || []).map(mapCommentThread));
    nextToken = response.nextToken;
  } while (nextToken && threads.length < 2000);
  return threads;
}

export interface PostPullRequestCommentParams {
  pullRequestId: string;
  repositoryName: string;
  beforeCommitId: string;
  afterCommitId: string;
  content: string;
  filePath?: string;
  filePosition?: number;
  relativeFileVersion?: 'BEFORE' | 'AFTER';
}

/** AWS's own limit on a comment's text. */
export const COMMENT_MAX_LENGTH = 10240;

/**
 * Rejects bad comment input before it reaches AWS (400 CardInput, shown in
 * the app's language): empty or over-long text, a line without a file, a
 * line that isn't a positive whole number, an unknown file side.
 */
export function checkCommentInput(input: { content?: unknown; filePath?: unknown; filePosition?: unknown; relativeFileVersion?: unknown }): void {
  const content = typeof input.content === 'string' ? input.content.trim() : '';
  if (!content) throw new CardInputError(t('The comment is empty', 'Yorum boş'));
  if (content.length > COMMENT_MAX_LENGTH) {
    throw new CardInputError(t(`A comment can be at most ${COMMENT_MAX_LENGTH} characters`, `Yorum en fazla ${COMMENT_MAX_LENGTH} karakter olabilir`));
  }
  if (input.filePath !== undefined && input.filePath !== null && typeof input.filePath !== 'string') {
    throw new CardInputError(t('The file path must be text', 'Dosya yolu metin olmalı'));
  }
  const hasFile = typeof input.filePath === 'string' && input.filePath.length > 0;
  if (input.filePosition !== undefined && input.filePosition !== null) {
    if (!hasFile) throw new CardInputError(t('A line comment needs a file', 'Satır yorumu için dosya gerekli'));
    if (typeof input.filePosition !== 'number' || !Number.isInteger(input.filePosition) || input.filePosition < 1) {
      throw new CardInputError(t('The line must be a whole number from 1', 'Satır 1 veya daha büyük bir tam sayı olmalı'));
    }
  }
  if (input.relativeFileVersion !== undefined && input.relativeFileVersion !== null) {
    if (!hasFile) throw new CardInputError(t('A file side needs a file', 'Dosya tarafı için dosya gerekli'));
    if (input.relativeFileVersion !== 'BEFORE' && input.relativeFileVersion !== 'AFTER') {
      throw new CardInputError(t('The file side must be BEFORE or AFTER', 'Dosya tarafı BEFORE ya da AFTER olmalı'));
    }
  }
}

// A general PR comment and an inline diff comment are the same API call -
// only whether `location` is set differs. One function covers both, which
// is what keeps the two "comment" features (general PR discussion, inline
// diff-line comments) from becoming two parallel, drifting code paths.
export async function postPullRequestComment(profile: string, region: string, params: PostPullRequestCommentParams): Promise<CodeCommitCommentThread> {
  const client = createClient(profile, region);
  const response = await client.send(
    new PostCommentForPullRequestCommand({
      pullRequestId: params.pullRequestId,
      repositoryName: params.repositoryName,
      beforeCommitId: params.beforeCommitId,
      afterCommitId: params.afterCommitId,
      content: params.content,
      location: params.filePath
        ? { filePath: params.filePath, filePosition: params.filePosition, relativeFileVersion: params.relativeFileVersion }
        : undefined,
    })
  );
  return mapCommentThread({
    location: response.location,
    beforeCommitId: response.beforeCommitId,
    afterCommitId: response.afterCommitId,
    comments: response.comment ? [response.comment] : [],
  });
}

export async function postCommentReply(profile: string, region: string, inReplyTo: string, content: string): Promise<CodeCommitComment> {
  const client = createClient(profile, region);
  const response = await client.send(new PostCommentReplyCommand({ inReplyTo, content }));
  const c = response.comment;
  return {
    commentId: c?.commentId || '',
    content: c?.content || '',
    inReplyTo: c?.inReplyTo,
    creationDate: c?.creationDate?.toISOString(),
    authorArn: c?.authorArn,
    deleted: c?.deleted,
  };
}

export async function deletePullRequestComment(profile: string, region: string, commentId: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteCommentContentCommand({ commentId }));
}

// MARK: - Pull request approvals

// Scoped to what the console's own "Approve"/"Revoke" button does for the
// calling user - authoring approval RULES (who must approve, how many)
// is a separate, much more involved JSON-rule-authoring flow that's out
// of scope here, same call as CloudFormation's "no full stack update".
export async function getPullRequestApprovals(profile: string, region: string, pullRequestId: string, revisionId: string): Promise<CodeCommitApproval[]> {
  const client = createClient(profile, region);
  const response = await client.send(new GetPullRequestApprovalStatesCommand({ pullRequestId, revisionId }));
  return (response.approvals || []).map((a) => ({ userArn: a.userArn || '', approvalState: a.approvalState || '' }));
}

export async function setPullRequestApproval(
  profile: string,
  region: string,
  pullRequestId: string,
  revisionId: string,
  approved: boolean
): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new UpdatePullRequestApprovalStateCommand({ pullRequestId, revisionId, approvalState: approved ? 'APPROVE' : 'REVOKE' }));
}

// MARK: - Pull request activity timeline

export async function getPullRequestEvents(profile: string, region: string, pullRequestId: string): Promise<CodeCommitPullRequestEvent[]> {
  const client = createClient(profile, region);
  const response = await client.send(new DescribePullRequestEventsCommand({ pullRequestId, maxResults: 100 }));
  return (response.pullRequestEvents || []).map((e) => ({
    eventDate: e.eventDate?.toISOString(),
    eventType: e.pullRequestEventType,
    actorArn: e.actorArn,
  }));
}

// MARK: - Repository triggers (CI/CD notifications)

export async function getRepositoryTriggers(profile: string, region: string, repositoryName: string): Promise<CodeCommitRepositoryTrigger[]> {
  const client = createClient(profile, region);
  const response = await client.send(new GetRepositoryTriggersCommand({ repositoryName }));
  return (response.triggers || []).map((t) => ({
    name: t.name || '',
    destinationArn: t.destinationArn || '',
    customData: t.customData,
    branches: t.branches || [],
    events: t.events || [],
  }));
}

export async function putRepositoryTriggers(profile: string, region: string, repositoryName: string, triggers: CodeCommitRepositoryTrigger[]): Promise<void> {
  const client = createClient(profile, region);
  await client.send(
    new PutRepositoryTriggersCommand({
      repositoryName,
      triggers: triggers.map((t) => ({
        name: t.name,
        destinationArn: t.destinationArn,
        customData: t.customData,
        branches: t.branches,
        events: t.events as RepositoryTriggerEventEnum[],
      })),
    })
  );
}

export async function testRepositoryTriggers(profile: string, region: string, repositoryName: string, triggers: CodeCommitRepositoryTrigger[]): Promise<string[]> {
  const client = createClient(profile, region);
  const response = await client.send(
    new TestRepositoryTriggersCommand({
      repositoryName,
      triggers: triggers.map((t) => ({
        name: t.name,
        destinationArn: t.destinationArn,
        customData: t.customData,
        branches: t.branches,
        events: t.events as RepositoryTriggerEventEnum[],
      })),
    })
  );
  return response.failedExecutions?.map((f) => `${f.trigger || 'trigger'}: ${f.failureMessage || 'failed'}`) || [];
}

// MARK: - File edit / direct commit (no local git checkout needed)

export interface PutFileParams {
  repositoryName: string;
  branchName: string;
  filePath: string;
  fileContent: string;
  commitMessage: string;
  parentCommitId?: string;
}

export async function putFile(profile: string, region: string, params: PutFileParams): Promise<string> {
  const client = createClient(profile, region);
  const response = await client.send(
    new PutFileCommand({
      repositoryName: params.repositoryName,
      branchName: params.branchName,
      fileContent: Buffer.from(params.fileContent, 'utf-8'),
      filePath: params.filePath,
      parentCommitId: params.parentCommitId,
      commitMessage: params.commitMessage,
    })
  );
  return response.commitId || '';
}

export async function deleteRepositoryFile(
  profile: string,
  region: string,
  repositoryName: string,
  branchName: string,
  filePath: string,
  commitMessage: string,
  parentCommitId: string
): Promise<string> {
  const client = createClient(profile, region);
  const response = await client.send(
    new DeleteFileCommand({ repositoryName, branchName, filePath, parentCommitId, commitMessage })
  );
  return response.commitId || '';
}

// MARK: - Paginated file search (for the quick file switcher)

// Bounds how many folders a single page request will walk regardless of
// how rare the query match is - without this, a query that matches
// nothing (or a huge repo) would walk the *entire* tree in one HTTP
// request before responding, which is exactly what was timing out the
// client. Capping per-page work means every request returns quickly;
// rare queries just take more "Load More" pages instead of one slow one.
const FILE_SEARCH_MAX_FOLDERS_PER_PAGE = 150;

// GetFolder is called round-by-round, `FILE_SEARCH_CONCURRENCY` folders at
// once via Promise.all rather than one at a time - each call is a network
// round-trip to CodeCommit (measured ~400ms), so walking the per-page cap
// serially took over a minute on a large repo (well past any reasonable
// client timeout). Fetching in concurrent batches cuts that to roughly
// (folders / concurrency) round-trips instead of one per folder.
const FILE_SEARCH_CONCURRENCY = 20;

export interface FileSearchPage {
  paths: string[];
  /** Folders whose name matches the query. */
  folders: string[];
  nextCursor: string | null;
}

/**
 * BFS-walks the folder tree (CodeCommit has no recursive listing or search
 * API) collecting files whose path contains `query`, stopping once `limit`
 * matches are found or the per-page folder cap is hit. `cursor` resumes a
 * previous page's walk - it's just the serialized remaining BFS queue, so
 * "Load More" continues exactly where the last page left off instead of
 * re-walking from the root. An empty `query` matches everything, which
 * doubles as plain paginated browsing.
 */
export async function searchFilePaths(
  profile: string,
  region: string,
  repositoryName: string,
  commitSpecifier: string,
  query: string,
  cursor: string | undefined,
  limit = 10
): Promise<FileSearchPage> {
  const client = createClient(profile, region);
  const queue: string[] = cursor ? JSON.parse(cursor) : ['/'];
  const needle = query.trim().toLowerCase();
  const matches: string[] = [];
  /** Folders whose own name matches - listed alongside the files. */
  const folders: string[] = [];
  let foldersExamined = 0;

  while (queue.length > 0 && matches.length < limit && foldersExamined < FILE_SEARCH_MAX_FOLDERS_PER_PAGE) {
    const batchSize = Math.min(FILE_SEARCH_CONCURRENCY, FILE_SEARCH_MAX_FOLDERS_PER_PAGE - foldersExamined, queue.length);
    const batch = queue.splice(0, batchSize);
    foldersExamined += batch.length;

    const responses = await Promise.all(
      batch.map((folderPath) => client.send(new GetFolderCommand({ repositoryName, folderPath, commitSpecifier })).catch(() => undefined))
    );

    for (const response of responses) {
      if (!response) continue;
      for (const f of response.files || []) {
        if (f.absolutePath && (!needle || f.absolutePath.toLowerCase().includes(needle))) {
          matches.push(f.absolutePath);
        }
      }
      for (const sub of response.subFolders || []) {
        if (!sub.absolutePath) continue;
        queue.push(sub.absolutePath);
        const name = (sub.absolutePath.split('/').pop() || '').toLowerCase();
        if (needle && name.includes(needle)) folders.push(sub.absolutePath);
      }
    }
  }

  return {
    paths: matches,
    folders,
    nextCursor: queue.length > 0 ? JSON.stringify(queue) : null,
  };
}
