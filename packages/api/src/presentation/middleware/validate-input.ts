import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { Request, Response, NextFunction } from 'express';
import { parseAwsConfig, getAwsConfigPath } from '../../infrastructure/aws/config-parser.js';

/**
 * One input check in front of every /api route, so no service file has to
 * repeat it and a bad value never costs an AWS call: the profile must exist,
 * the region must look like an AWS region, ids must have a sane length and
 * tags must follow AWS's tag rules.
 *
 * A rejection is a 400 with `type: 'ValidationError'`, a stable `code`
 * (e.g. `TagKeyTooLong`) and `params` - the app turns `code` + `params`
 * into a message in the user's language; `error` is the English fallback.
 */

export type ValidationCode =
  | 'ProfileNotFound'
  | 'RegionInvalid'
  | 'IdTooLong'
  | 'TagKeyEmpty'
  | 'TagKeyTooLong'
  | 'TagKeyReserved'
  | 'TagValueTooLong';

/** AWS limits (characters, not bytes) shared by every service's tags. */
export const TAG_KEY_MAX = 128;
export const TAG_VALUE_MAX = 256;
/** Longest id we pass on - ARNs top out around 2 KB. */
export const ID_MAX = 2048;

/**
 * Shape check, not a fixed list, so a region AWS opens next month still
 * works: `eu-west-1`, `us-gov-west-1`, `cn-north-1`, `us-isob-east-1`.
 */
const REGION_PATTERN = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;

export class ValidationError extends Error {
  constructor(
    readonly code: ValidationCode,
    message: string,
    readonly field: string,
    readonly params: Record<string, string | number> = {},
  ) {
    super(message);
    this.name = 'ValidationError';
  }

  toJSON() {
    return { error: this.message, type: 'ValidationError', code: this.code, status: 400, field: this.field, params: this.params };
  }
}

// ---- Profiles (~/.aws/config + ~/.aws/credentials), re-read when either file changes

let profileCache: { stamp: string; names: Set<string> } | undefined;

function mtime(path: string): string {
  try {
    return String(statSync(path).mtimeMs);
  } catch {
    return '-';
  }
}

function knownProfiles(): Set<string> {
  const credentialsPath = process.env.AWS_SHARED_CREDENTIALS_FILE || join(homedir(), '.aws', 'credentials');
  const stamp = `${mtime(getAwsConfigPath())}|${mtime(credentialsPath)}`;
  if (profileCache?.stamp === stamp) return profileCache.names;

  const names = new Set(parseAwsConfig().profiles.map((p) => p.name));
  try {
    for (const match of readFileSync(credentialsPath, 'utf-8').matchAll(/^\s*\[([^\]]+)\]\s*$/gm)) names.add(match[1].trim());
  } catch {
    // no credentials file - config profiles only
  }
  profileCache = { stamp, names };
  return names;
}

// ---- Individual checks (exported for tests)

const chars = (s: string) => [...s].length;

export function checkProfile(profile: string): void {
  // Empty = the SDK's default credential chain; AWS_PROFILE etc. stay possible.
  if (!profile) return;
  if (!knownProfiles().has(profile)) {
    throw new ValidationError('ProfileNotFound', `Profile "${profile}" is not in ~/.aws/config or ~/.aws/credentials`, 'profile', { profile });
  }
}

export function checkRegion(region: string): void {
  if (!region) return;
  if (!REGION_PATTERN.test(region)) {
    throw new ValidationError('RegionInvalid', `"${region}" is not an AWS region (expected something like eu-west-1)`, 'region', { region });
  }
}

export function checkId(field: string, id: unknown): void {
  if (typeof id === 'string' && chars(id) > ID_MAX) {
    throw new ValidationError('IdTooLong', `${field} is longer than ${ID_MAX} characters`, field, { max: ID_MAX });
  }
}

export function checkTag(key: unknown, value: unknown, adding: boolean): void {
  if (typeof key !== 'string' || key.trim() === '') {
    throw new ValidationError('TagKeyEmpty', 'Tag key cannot be empty', 'key');
  }
  if (chars(key) > TAG_KEY_MAX) {
    throw new ValidationError('TagKeyTooLong', `Tag key can be at most ${TAG_KEY_MAX} characters (got ${chars(key)})`, 'key', { max: TAG_KEY_MAX, length: chars(key) });
  }
  // Only on add: removing an existing `aws:` tag should still say what AWS says.
  if (adding && key.toLowerCase().startsWith('aws:')) {
    throw new ValidationError('TagKeyReserved', 'Tag keys starting with "aws:" are reserved for AWS', 'key');
  }
  if (adding && typeof value === 'string' && chars(value) > TAG_VALUE_MAX) {
    throw new ValidationError('TagValueTooLong', `Tag value can be at most ${TAG_VALUE_MAX} characters (got ${chars(value)})`, 'value', { max: TAG_VALUE_MAX, length: chars(value) });
  }
}

/** `/…/tags` adds a tag, `/…/tags/remove` removes one - same body fields on every service. */
const TAG_ROUTE = /\/tags(\/remove)?$/;

export function validateInput(req: Request, res: Response, next: NextFunction): void {
  try {
    const query = req.query as Record<string, unknown>;
    const body = (req.body && typeof req.body === 'object' ? req.body : {}) as Record<string, unknown>;

    if (typeof query.profile === 'string') checkProfile(query.profile);
    if (typeof query.region === 'string') checkRegion(query.region);
    checkId('id', query.id);
    checkId('id', body.id);

    const tagRoute = req.method === 'POST' ? req.path.match(TAG_ROUTE) : null;
    if (tagRoute) checkTag(body.key, body.value, !tagRoute[1]);

    next();
  } catch (err) {
    if (!(err instanceof ValidationError)) throw err;
    res.status(400).json(err.toJSON());
  }
}
