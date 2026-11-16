import type { Request, Response } from 'express';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

/** `profile`/`region` query params every per-service route takes. */
export function profileRegion(req: Request): { profile: string; region: string } {
  return {
    profile: (req.query.profile as string) || '',
    region: (req.query.region as string) || '',
  };
}

/**
 * The try / `res.json` / `handleApiError` block every detail and mutation
 * route repeats - `undefined` results answer `{ ok: true }`.
 */
export async function respond<T>(res: Response, fn: () => Promise<T>): Promise<void> {
  try {
    const result = await fn();
    res.json(result === undefined ? { ok: true } : result);
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
}

/** Sends a 400 naming the missing fields; returns true when any are missing. */
export function rejectMissing(res: Response, fields: Record<string, unknown>): boolean {
  const missing = Object.entries(fields)
    .filter(([, v]) => v === undefined || v === null || v === '')
    .map(([k]) => k);
  if (missing.length === 0) return false;
  res.status(400).json({ error: `${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} required` });
  return true;
}
