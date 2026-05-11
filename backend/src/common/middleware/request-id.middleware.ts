import { randomUUID } from 'node:crypto';
import { type NextFunction, type Request, type Response } from 'express';
import { logMessage } from '../logging/app-logger';
import { runWithRequestContext } from '../logging/request-context';

const REQUEST_ID_HEADER = 'x-request-id';
type RequestWithId = Request & { requestId?: string };

function normalizeRequestId(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (!/^[A-Za-z0-9._:/-]{6,128}$/.test(trimmed)) return null;
  return trimmed;
}

function resolveRequestId(headerValue: string | string[] | undefined): string {
  if (Array.isArray(headerValue)) {
    for (const item of headerValue) {
      const normalized = normalizeRequestId(item);
      if (normalized) return normalized;
    }
  }
  const normalized = normalizeRequestId(headerValue);
  return normalized ?? randomUUID();
}

export function requestIdMiddleware(req: Request, res: Response, next: NextFunction): void {
  const request = req as RequestWithId;
  const requestId = resolveRequestId(req.headers[REQUEST_ID_HEADER]);
  request.requestId = requestId;
  res.setHeader(REQUEST_ID_HEADER, requestId);

  const start = Date.now();
  res.on('finish', () => {
    const durationMs = Date.now() - start;
    const statusCode = res.statusCode;
    const level = statusCode >= 500 ? 'error' : statusCode >= 400 ? 'warn' : 'info';
    logMessage(level, 'http_request', {
      requestId,
      method: req.method,
      path: req.originalUrl ?? req.url,
      durationMs,
      statusCode,
    });
  });

  runWithRequestContext({ requestId }, () => next());
}

export const __internal = {
  normalizeRequestId,
  resolveRequestId,
};
