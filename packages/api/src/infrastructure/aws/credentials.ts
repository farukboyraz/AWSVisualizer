import { cachedCredentials } from './credential-cache.js';

const AUTH_ERROR_CODES = new Set([
  'ExpiredToken',
  'ExpiredTokenException',
  'InvalidIdentityToken',
  'AuthFailure',
  'InvalidClientTokenId',
  'SignatureDoesNotMatch',
  'CredentialsError',
  // The AWS SDK's own error when a profile's cached SSO role credentials
  // are missing or stale (e.g. `aws sso login` was never run for that
  // specific profile, or its session token aged out) - its message reads
  // "SSO session token ... was not found or is invalid", which doesn't
  // contain any of the substrings matched below, so without this it fell
  // through as a generic 500 instead of the "Not Authorized" the frontend
  // is built to show for auth problems.
  'CredentialsProviderError',
  'NoSuchTokenException',
  'TokenExpiredException',
  'UnrecognizedClientException',
]);

const ACCESS_DENIED_CODES = [
  'AccessDeniedException',
  'AccessDenied',
  'UnauthorizedException',
  'UnauthorizedAccess',
  'Forbidden',
  'OptInRequired',
];

/**
 * Throttling / network trouble while resolving credentials or calling AWS -
 * not an expired session. The SSO portal throttles `GetRoleCredentials`
 * and the SDK wraps that in a CredentialsProviderError, which used to be
 * reported as "session expired" (see `credential-cache.ts`).
 */
export function isTransientError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const error = err as { name?: string; Code?: string; code?: string; message?: string; $metadata?: { httpStatusCode?: number } };
  const code = error.name || error.Code || error.code || '';
  if (['TooManyRequestsException', 'ThrottlingException', 'Throttling', 'TimeoutError', 'RequestTimeout', 'RequestTimeoutException'].includes(code)) return true;
  // A 4xx answer from AWS itself (validation, not found…) isn't transient
  // even if its text mentions e.g. a "Timeout" setting.
  const status = error.$metadata?.httpStatusCode;
  if (status && status >= 400 && status < 500 && status !== 429) return false;
  const message = (error.message || '').toLowerCase();
  return ['too many requests', 'rate exceeded', 'throttl', 'timed out', 'timeout', 'etimedout', 'econnreset', 'econnrefused', 'socket hang up', 'eai_again', 'enotfound', 'network'].some((m) => message.includes(m));
}

export function isAuthError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  if (isTransientError(err)) return false;

  const error = err as { name?: string; Code?: string; code?: string; message?: string };
  const code = error.name || error.Code || error.code || '';

  if (AUTH_ERROR_CODES.has(code)) return true;

  const message = (error.message || '').toLowerCase();
  if (
    message.includes('expired') ||
    message.includes('not authorized') ||
    message.includes('security token') ||
    message.includes('credentials') ||
    message.includes('sso session')
  ) {
    return true;
  }

  return false;
}

export function isAccessDenied(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const error = err as { name?: string; Code?: string; code?: string; message?: string };
  const code = error.name || error.Code || error.code || '';
  const message = error.message || '';

  if (ACCESS_DENIED_CODES.includes(code)) return true;
  if (
    message.includes('not authorized') ||
    message.includes('Access Denied') ||
    message.includes('is not authorized')
  ) {
    return true;
  }

  return false;
}

export interface ApiError {
  error: string;
  type: string;
  code: string;
  status: number;
  /** PackageMissing (424): the npm packages / catalog services the request needed. */
  packages?: string[];
  services?: string[];
  /** CardInput (400): what's wrong with a form value, in English and Turkish. */
  text?: { en: string; tr: string };
}

export function handleApiError(err: unknown): ApiError {
  if (!err || typeof err !== 'object') {
    return {
      error: 'Unknown error',
      type: 'UnknownError',
      code: 'Unknown',
      status: 500,
    };
  }

  const error = err as {
    name?: string;
    message?: string;
    Code?: string;
    code?: string;
    $metadata?: { httpStatusCode?: number };
  };

  const code = error.name || error.Code || error.code || 'Unknown';
  const message = error.message || 'An unexpected error occurred';

  // A form value broke a field rule (infrastructure/form-fields.ts).
  if (error.name === 'CardInputError') {
    const input = err as { text?: { en: string; tr: string } };
    return { error: message, type: 'CardInput', code, status: 400, text: input.text };
  }

  if (error.name === 'PackageMissing') {
    const missing = err as { packages?: string[]; services?: string[] };
    return { error: message, type: 'PackageMissing', code, status: 424, packages: missing.packages, services: missing.services };
  }

  if (isTransientError(err)) {
    return { error: message, type: 'TransientError', code, status: 503 };
  }
  // Missing IAM permission - the session itself is fine.
  if (isAccessDenied(err)) {
    return { error: message, type: 'AccessDenied', code, status: 403 };
  }
  if (isAuthError(err)) {
    return {
      error: message,
      type: 'AuthError',
      code,
      status: 401,
    };
  }

  const httpStatus = error.$metadata?.httpStatusCode || 500;

  return {
    error: message,
    type: 'ServiceError',
    code,
    status: httpStatus,
  };
}

/**
 * Creates an AWS SDK client with the shared per-profile credentials (`cachedCredentials`).
 */
export function createClient<T>(
  ClientClass: new (config: { region: string; credentials: ReturnType<typeof cachedCredentials> }) => T,
  profile: string,
  region: string
): T {
  return new ClientClass({
    region,
    credentials: cachedCredentials(profile),
  });
}
