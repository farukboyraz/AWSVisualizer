import type { Request, Response, NextFunction } from 'express';
import { handleApiError } from '../../infrastructure/aws/credentials.js';

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction): void {
  const apiError = handleApiError(err);
  res.status(apiError.status).json(apiError);
}
