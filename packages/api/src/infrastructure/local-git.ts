import { execFile } from 'child_process';
import { promisify } from 'util';
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { getWorkspacePath, saveWorkspacePath, removeWorkspacePath, listWorkspaces } from '../config/index.js';
import { buildFileDiff } from './diff-utils.js';
import type { CodeCommitFileDiff } from '../domain/entities/index.js';

const execFileAsync = promisify(execFile);

/**
 * Real `git` operating on a real local clone - unlike everything else in
 * this app, this never touches the CodeCommit API. It exists because
 * CodeCommit's REST API has no concept of push/pull/merge-into-a-working-
 * copy; those are git-protocol operations that only make sense against an
 * actual local checkout.
 */

export type GitOutcome = 'success' | 'conflict' | 'rejectedNonFastForward' | 'uncommittedChanges' | 'nothingToPush' | 'error';

export interface GitCommandResult {
  outcome: GitOutcome;
  stdout: string;
  stderr: string;
  conflictedFiles: string[];
}

export interface WorkspaceStatus {
  localPath: string | null;
  /** `localPath` is set but the folder is missing or no longer a git repo (moved/deleted outside the app). */
  isMissing: boolean;
  currentBranch: string | null;
  isDirty: boolean;
  ahead: number | null;
  behind: number | null;
}

export interface MatchResult {
  success: boolean;
  /** Non-fatal - e.g. the folder's remote doesn't obviously look like this
   * repo. Still saved; the user picked this folder on purpose. */
  warning?: string;
}

export interface LocalDiffFile {
  path: string;
  changeType: 'A' | 'M' | 'D';
  additions: number;
  deletions: number;
  binary: boolean;
}

function isValidProfileName(profile: string): boolean {
  return /^[\w.@-]+$/.test(profile);
}

/**
 * Every command gets these `-c` overrides, not just the ones that obviously
 * talk to the remote - harmless for purely-local commands (status, diff),
 * and means auth is never dependent on the user's own global git config or
 * on this app writing a permanent credential helper into their repo.
 * `aws codecommit credential-helper` is the AWS CLI's own subcommand for
 * this - no extra dependency beyond the AWS CLI this app already requires
 * for SSO.
 */
function credentialConfigArgs(profile: string): string[] {
  if (!isValidProfileName(profile)) throw new Error(`Invalid AWS profile name: ${profile}`);
  return [
    '-c', `credential.helper=!aws codecommit credential-helper --profile ${profile} $@`,
    '-c', 'credential.UseHttpPath=true',
  ];
}

interface RawGitResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

async function runGit(args: string[], cwd: string, timeoutMs = 180_000): Promise<RawGitResult> {
  try {
    const { stdout, stderr } = await execFileAsync('git', args, { cwd, timeout: timeoutMs, maxBuffer: 1024 * 1024 * 20 });
    return { stdout, stderr, exitCode: 0 };
  } catch (err: any) {
    return {
      stdout: err.stdout ?? '',
      stderr: err.stderr || err.message || 'git command failed',
      exitCode: typeof err.code === 'number' ? err.code : 1,
    };
  }
}

/** Actual conflicted paths, read from git itself rather than parsed out of
 * free-text output - `git diff --diff-filter=U` lists exactly the paths
 * still in the "unmerged" state, regardless of which command caused it. */
async function detectConflictedFiles(localPath: string): Promise<string[]> {
  const result = await runGit(['diff', '--name-only', '--diff-filter=U'], localPath);
  return result.stdout.split('\n').map((s) => s.trim()).filter(Boolean);
}

async function classify(result: RawGitResult, localPath: string, kind: 'pull' | 'push' | 'merge'): Promise<GitCommandResult> {
  if (result.exitCode === 0) {
    return { outcome: 'success', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
  }

  const combined = `${result.stdout}\n${result.stderr}`;

  if (combined.includes('CONFLICT') || combined.includes('Automatic merge failed')) {
    const conflictedFiles = await detectConflictedFiles(localPath);
    return { outcome: 'conflict', stdout: result.stdout, stderr: result.stderr, conflictedFiles };
  }
  if (kind === 'push' && (combined.includes('[rejected]') || combined.includes('fetch first') || combined.includes('non-fast-forward'))) {
    return { outcome: 'rejectedNonFastForward', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
  }
  if (combined.includes('Please commit your changes or stash them') || combined.includes('overwritten by merge') || combined.includes('Your local changes to the following files would be overwritten')) {
    return { outcome: 'uncommittedChanges', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
  }
  if (kind === 'push' && combined.includes('Everything up-to-date')) {
    return { outcome: 'success', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
  }

  return { outcome: 'error', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
}

export function getSavedWorkspacePath(repositoryName: string): string | undefined {
  return getWorkspacePath(repositoryName);
}

export function forgetWorkspace(repositoryName: string): void {
  removeWorkspacePath(repositoryName);
}

export async function getWorkspaceStatus(repositoryName: string): Promise<WorkspaceStatus> {
  const localPath = getWorkspacePath(repositoryName);
  if (!localPath) {
    return { localPath: null, isMissing: false, currentBranch: null, isDirty: false, ahead: null, behind: null };
  }
  if (!existsSync(join(localPath, '.git'))) {
    return { localPath, isMissing: true, currentBranch: null, isDirty: false, ahead: null, behind: null };
  }

  const branchResult = await runGit(['rev-parse', '--abbrev-ref', 'HEAD'], localPath);
  const currentBranch = branchResult.exitCode === 0 ? branchResult.stdout.trim() : null;

  const statusResult = await runGit(['status', '--porcelain'], localPath);
  const isDirty = statusResult.exitCode === 0 && statusResult.stdout.trim().length > 0;

  let ahead: number | null = null;
  let behind: number | null = null;
  const countResult = await runGit(['rev-list', '--left-right', '--count', 'HEAD...@{u}'], localPath);
  if (countResult.exitCode === 0) {
    const parts = countResult.stdout.trim().split(/\s+/).map(Number);
    if (parts.length === 2 && parts.every((n) => !Number.isNaN(n))) {
      [ahead, behind] = parts;
    }
  }

  return { localPath, isMissing: false, currentBranch, isDirty, ahead, behind };
}

export async function cloneWorkspace(profile: string, repositoryName: string, cloneUrl: string, parentDirectory: string): Promise<GitCommandResult> {
  const destination = join(parentDirectory, repositoryName);
  if (existsSync(destination)) {
    throw new Error(`"${destination}" already exists - remove it or choose a different folder first.`);
  }
  const result = await runGit([...credentialConfigArgs(profile), 'clone', cloneUrl, destination], parentDirectory, 300_000);
  if (result.exitCode === 0) {
    saveWorkspacePath(repositoryName, destination);
    return { outcome: 'success', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
  }
  return { outcome: 'error', stdout: result.stdout, stderr: result.stderr, conflictedFiles: [] };
}

/** Every repo -> local path association currently saved (Settings' "which
 * projects have a workspace" list, and app-startup preloading). */
export function listAllWorkspaces(): { repositoryName: string; localPath: string }[] {
  return listWorkspaces();
}

/** Links an *already-existing* local clone to this repo, without running
 * `git clone` - for the common case where the user cloned it themselves (or
 * years ago) and just wants the app to know where it is. Only validates
 * that it's a real git repo; doesn't require the remote to match, since a
 * fork/mirror/differently-configured-remote local checkout of the same
 * codebase is still a legitimate thing to point at. */
export async function matchWorkspace(repositoryName: string, cloneUrlHttp: string | undefined, localPath: string): Promise<MatchResult> {
  if (!existsSync(join(localPath, '.git'))) {
    throw new Error(`"${localPath}" doesn't look like a git repository - no .git folder found there.`);
  }
  const rootResult = await runGit(['rev-parse', '--is-inside-work-tree'], localPath);
  if (rootResult.exitCode !== 0 || rootResult.stdout.trim() !== 'true') {
    throw new Error(`"${localPath}" doesn't look like a usable git working tree.`);
  }

  let warning: string | undefined;
  if (cloneUrlHttp) {
    const remoteResult = await runGit(['remote', 'get-url', 'origin'], localPath);
    if (remoteResult.exitCode === 0 && !remoteResult.stdout.trim().includes(repositoryName)) {
      warning = `This folder's remote doesn't look like "${repositoryName}" - double check this is the right one.`;
    }
  }

  saveWorkspacePath(repositoryName, localPath);
  return { success: true, warning };
}

export async function pullWorkspace(profile: string, repositoryName: string): Promise<GitCommandResult> {
  const localPath = requireWorkspace(repositoryName);
  const result = await runGit([...credentialConfigArgs(profile), 'pull'], localPath);
  return classify(result, localPath, 'pull');
}

export async function pushWorkspace(profile: string, repositoryName: string): Promise<GitCommandResult> {
  const localPath = requireWorkspace(repositoryName);
  const result = await runGit([...credentialConfigArgs(profile), 'push'], localPath);
  return classify(result, localPath, 'push');
}

/** Merges `branchName` (fetched fresh from origin first) into whatever
 * branch the local workspace currently has checked out. */
export async function mergeBranchIntoWorkspace(profile: string, repositoryName: string, branchName: string): Promise<GitCommandResult> {
  const localPath = requireWorkspace(repositoryName);
  const fetchResult = await runGit([...credentialConfigArgs(profile), 'fetch', 'origin', branchName], localPath);
  if (fetchResult.exitCode !== 0) {
    return { outcome: 'error', stdout: fetchResult.stdout, stderr: fetchResult.stderr, conflictedFiles: [] };
  }
  const mergeResult = await runGit(['merge', `origin/${branchName}`, '-m', `Merge branch '${branchName}'`], localPath);
  return classify(mergeResult, localPath, 'merge');
}

function parseNumstat(output: string): Map<string, { additions: number; deletions: number; binary: boolean }> {
  const map = new Map<string, { additions: number; deletions: number; binary: boolean }>();
  for (const line of output.split('\n')) {
    if (!line.trim()) continue;
    const [add, del, path] = line.split('\t');
    const binary = add === '-' || del === '-';
    map.set(path, { additions: binary ? 0 : parseInt(add, 10), deletions: binary ? 0 : parseInt(del, 10), binary });
  }
  return map;
}

function parseNameStatus(output: string): Map<string, 'A' | 'M' | 'D'> {
  const map = new Map<string, 'A' | 'M' | 'D'>();
  for (const line of output.split('\n')) {
    if (!line.trim()) continue;
    const [status, path] = line.split('\t');
    const type: 'A' | 'M' | 'D' = status.startsWith('A') ? 'A' : status.startsWith('D') ? 'D' : 'M';
    map.set(path, type);
  }
  return map;
}

/** Fetches `branch` fresh from origin, then diffs the workspace's current
 * state (working tree + any uncommitted edits, not just its last commit -
 * same as a plain `git diff <ref>`) against it. This is deliberately about
 * "what's different between what's on my disk right now and this branch",
 * not a commit-to-commit comparison like CodeCommit's own diff views. */
export async function getLocalDiffSummary(profile: string, repositoryName: string, branch: string): Promise<LocalDiffFile[]> {
  const localPath = requireWorkspace(repositoryName);
  const fetchResult = await runGit([...credentialConfigArgs(profile), 'fetch', 'origin', branch], localPath);
  if (fetchResult.exitCode !== 0) {
    throw new Error(fetchResult.stderr || `Couldn't fetch "${branch}" from origin.`);
  }

  const [numstatResult, nameStatusResult] = await Promise.all([
    runGit(['diff', '--no-renames', '--numstat', 'FETCH_HEAD'], localPath),
    runGit(['diff', '--no-renames', '--name-status', 'FETCH_HEAD'], localPath),
  ]);
  const stats = parseNumstat(numstatResult.stdout);
  const types = parseNameStatus(nameStatusResult.stdout);

  return [...stats.entries()].map(([path, stat]) => ({
    path,
    changeType: types.get(path) ?? 'M',
    additions: stat.additions,
    deletions: stat.deletions,
    binary: stat.binary,
  }));
}

/** Same "workspace vs. fetched branch" comparison as `getLocalDiffSummary`,
 * but for one file's full text - reuses the exact same `structuredPatch`
 * pipeline CodeCommit's own diff view uses (`diff-utils.ts`), so the result
 * is the same `CodeCommitFileDiff` shape and can be rendered by the same
 * Swift view regardless of which source it came from. */
export async function getLocalFileDiff(profile: string, repositoryName: string, branch: string, path: string, fullFile = false): Promise<CodeCommitFileDiff> {
  const localPath = requireWorkspace(repositoryName);
  const fetchResult = await runGit([...credentialConfigArgs(profile), 'fetch', 'origin', branch], localPath);
  if (fetchResult.exitCode !== 0) {
    throw new Error(fetchResult.stderr || `Couldn't fetch "${branch}" from origin.`);
  }

  const beforeResult = await runGit(['show', `FETCH_HEAD:${path}`], localPath);
  const hadBefore = beforeResult.exitCode === 0;

  const fullPath = join(localPath, path);
  const hasAfter = existsSync(fullPath);
  let afterText = '';
  if (hasAfter) {
    try {
      afterText = readFileSync(fullPath, 'utf-8');
    } catch {
      return { path, changeType: hadBefore ? 'M' : 'A', binary: true, additions: 0, deletions: 0, hunks: [] };
    }
  }

  const changeType: 'A' | 'M' | 'D' = !hadBefore ? 'A' : !hasAfter ? 'D' : 'M';
  return buildFileDiff(path, changeType, hadBefore ? beforeResult.stdout : '', afterText, fullFile);
}

function requireWorkspace(repositoryName: string): string {
  const localPath = getWorkspacePath(repositoryName);
  if (!localPath) throw new Error('No local clone for this repository yet - use Clone first.');
  if (!existsSync(join(localPath, '.git'))) {
    throw new Error(`"${localPath}" no longer looks like a git checkout - it may have been moved or deleted outside the app.`);
  }
  return localPath;
}
