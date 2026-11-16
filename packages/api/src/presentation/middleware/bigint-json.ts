import express from 'express';
import type { NextFunction, Request, Response } from 'express';

/**
 * DynamoDB numbers can be up to 38 digits, but JS numbers lose precision past
 * 2^53 (e.g. .NET DateTime ticks like 639268855002322890). `unmarshall()`
 * returns those as BigInt, which plain `JSON.stringify` refuses to serialize,
 * and plain `JSON.parse` would silently round them on the way back in.
 *
 * These helpers keep such integers exact in both directions: they are written
 * to responses as raw JSON integers and parsed from request bodies as BigInt
 * (which `marshall()` stores back as the same `N` value).
 */

const MARKER = '\u0000bigint:';
const MARKER_PATTERN = /"\\u0000bigint:(-?\d+)"/g;
const MAX_SAFE_DIGITS = String(Number.MAX_SAFE_INTEGER).length;

export function stringifyJson(value: unknown): string {
  const text = JSON.stringify(value, (_key, v) => (typeof v === 'bigint' ? `${MARKER}${v.toString()}` : v));
  return text === undefined ? text : text.replace(MARKER_PATTERN, '$1');
}

/** Wraps integer literals that don't fit a JS number in marker strings, skipping string contents. */
function protectUnsafeIntegers(text: string): string {
  let out = '';
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j + 1;
      continue;
    }
    if (ch === '-' || (ch >= '0' && ch <= '9')) {
      let j = i + 1;
      while (j < text.length && /[0-9.eE+-]/.test(text[j])) j++;
      const token = text.slice(i, j);
      const digits = token.replace('-', '');
      const isUnsafeInteger =
        /^-?\d+$/.test(token) && digits.length >= MAX_SAFE_DIGITS && !Number.isSafeInteger(Number(token));
      out += isUnsafeInteger ? `"\\u0000bigint:${token}"` : token;
      i = j;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

export function parseJson(text: string): unknown {
  return JSON.parse(protectUnsafeIntegers(text), (_key, v) =>
    typeof v === 'string' && v.startsWith(MARKER) ? BigInt(v.slice(MARKER.length)) : v
  );
}

export const bigIntJsonBody = [
  express.text({ type: 'application/json', limit: '100kb' }),
  (req: Request, res: Response, next: NextFunction) => {
    if (typeof req.body !== 'string') return next();
    if (req.body.trim() === '') {
      req.body = {};
      return next();
    }
    try {
      req.body = parseJson(req.body);
      next();
    } catch {
      res.status(400).json({ error: 'Invalid JSON body' });
    }
  },
];

export function bigIntJsonResponse(_req: Request, res: Response, next: NextFunction) {
  res.json = (body?: unknown) => {
    if (!res.get('Content-Type')) res.type('application/json');
    return res.send(stringifyJson(body));
  };
  next();
}
