import { randomBytes, timingSafeEqual } from 'node:crypto';
import type { Request, Response, NextFunction } from 'express';

/**
 * Only the Mac app may use the sidecar. It makes a random secret on every
 * launch, passes it in `AWSVIS_TOKEN` when it starts the sidecar, and sends
 * it back on every request in this header. Requests without it - another
 * program on this Mac, or a web page that points `fetch` at localhost - are
 * rejected before any AWS call. (Browsers can't add a custom header to a
 * cross-origin request without a CORS preflight, which the sidecar no
 * longer answers.)
 */
export const SIDECAR_TOKEN_HEADER = 'x-awsvisualizer-token';

const configured = process.env.AWSVIS_TOKEN?.trim();
const token = Buffer.from(configured || randomBytes(32).toString('hex'));

if (!configured) {
  // Started by hand (`npm run dev`): nothing can call it without the token,
  // so print it for curl / debugging. The app always sets its own.
  console.warn(`⚠️  AWSVIS_TOKEN not set - generated one for this run. Send it as "${SIDECAR_TOKEN_HEADER}: ${token.toString()}"`);
}

export function requireSidecarToken(req: Request, res: Response, next: NextFunction): void {
  const sent = Buffer.from(req.get(SIDECAR_TOKEN_HEADER) ?? '');
  if (sent.length === token.length && timingSafeEqual(sent, token)) {
    next();
    return;
  }
  res.status(403).json({
    error: 'This local API only accepts requests from the AWS Visualizer app.',
    type: 'SidecarAuth',
    code: 'SidecarTokenInvalid',
    status: 403,
  });
}
