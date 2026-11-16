import type { Response } from 'express';
import { isAuthError, isAccessDenied, handleApiError } from '../../infrastructure/aws/credentials.js';

/**
 * Express version of withAuthGuard.
 * - Success: { authorized: true, data: T }
 * - Auth/Access error: { authorized: false, message: 'Not Authorized' } (HTTP 200)
 * - Other errors: standard error response
 */
export async function withAuthGuard<T>(res: Response, fn: () => Promise<T>): Promise<void> {
  try {
    const data = await fn();
    res.json({ authorized: true, data });
  } catch (err: unknown) {
    if (isAccessDenied(err) || isAuthError(err)) {
      res.status(200).json({ authorized: false, message: 'Not Authorized' });
      return;
    }

    const apiError = handleApiError(err);
    res.status(apiError.status).json(apiError);
  }
}
