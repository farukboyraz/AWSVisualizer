import { structuredPatch } from 'diff';
import type { CodeCommitFileDiff, CodeCommitDiffLine } from '../domain/entities/index.js';

/**
 * Shared by CodeCommit's own diff (`codecommit.ts#getFileDiff`, comparing
 * two blobs from the API) and the Workspace tab's local diff
 * (`local-git.ts`, comparing a local file against a fetched branch ref) -
 * same unified-diff-to-hunks shape either way, so both can feed the same
 * Swift diff renderer (`CodeCommitFileDiff`) without it needing to know or
 * care which source the text came from.
 */
/**
 * `fullFile: true` = the whole file as context (one hunk covering every
 * line) - the app's "File" mode shows the complete old and new file side
 * by side with the changes highlighted, not just the changed regions.
 */
export function buildFileDiff(path: string, changeType: 'A' | 'M' | 'D', beforeText: string, afterText: string, fullFile = false): CodeCommitFileDiff {
  const context = fullFile ? Math.max(beforeText.split('\n').length, afterText.split('\n').length) + 1 : 3;
  const patch = structuredPatch(path, path, beforeText, afterText, undefined, undefined, { context });
  let additions = 0;
  let deletions = 0;
  const hunks = patch.hunks.map((hunk) => {
    const lines: CodeCommitDiffLine[] = hunk.lines.map((line) => {
      if (line.startsWith('+')) {
        additions++;
        return { type: 'add', text: line.slice(1) };
      }
      if (line.startsWith('-')) {
        deletions++;
        return { type: 'del', text: line.slice(1) };
      }
      return { type: 'context', text: line.slice(1) };
    });
    return {
      header: `@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@`,
      lines,
    };
  });

  return { path, changeType, binary: false, additions, deletions, hunks };
}
