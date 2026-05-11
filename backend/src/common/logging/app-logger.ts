import { getRequestIdFromContext } from './request-context';

export type AppLogLevel = 'debug' | 'info' | 'warn' | 'error';

const LONG_TEXT_KEYS = new Set([
  'sourceText',
  'targetText',
  'chunkText',
  'content',
  'prompt',
  'response',
  'translatedText',
]);

function isSensitiveKey(key: string): boolean {
  const normalized = key.toLowerCase();
  if (normalized === 'authorization') return true;
  if (normalized === 'apikey' || normalized === 'api_key') return true;
  if (normalized === 'password' || normalized === 'secret') return true;
  if (normalized === 'token' || normalized === 'access_token' || normalized === 'refresh_token') return true;
  if (normalized.endsWith('apikey') || normalized.endsWith('_api_key')) return true;
  if (normalized.endsWith('_token') || normalized.endsWith('tokenvalue')) return true;
  return false;
}

const LOG_LEVEL_PRIORITY: Record<AppLogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

export interface AppLogMeta {
  requestId?: string;
  businessCode?: string;
  path?: string;
  method?: string;
  durationMs?: number;
  [key: string]: unknown;
}

type LogFormat = 'text' | 'json';

function resolveLogFormat(): LogFormat {
  const envValue = (process.env.LOG_FORMAT ?? '').trim().toLowerCase();
  if (envValue === 'json' || envValue === 'text') return envValue;
  return process.env.NODE_ENV === 'production' ? 'json' : 'text';
}

function resolveLogLevel(): AppLogLevel {
  const envValue = (process.env.LOG_LEVEL ?? '').trim().toLowerCase();
  if (envValue === 'debug' || envValue === 'info' || envValue === 'warn' || envValue === 'error') {
    return envValue;
  }
  return 'info';
}

function shouldLog(level: AppLogLevel): boolean {
  return LOG_LEVEL_PRIORITY[level] >= LOG_LEVEL_PRIORITY[resolveLogLevel()];
}

function redactString(value: string): string {
  const maskedKey = value.replace(/\bsk-[A-Za-z0-9._-]+\b/g, 'sk-***');
  return maskedKey.replace(/\b(Bearer)\s+[^\s,;]+/gi, '$1 ***');
}

function summarizeText(value: string): { length: number; preview: string } {
  return {
    length: value.length,
    preview: redactString(value.slice(0, 120)),
  };
}

function sanitizeValue(value: unknown, key?: string, depth = 0): unknown {
  if (depth > 5) return '[TRUNCATED]';
  if (value === null || value === undefined) return value;

  if (typeof value === 'string') {
    if ((key && LONG_TEXT_KEYS.has(key)) || value.length > 2000) {
      return summarizeText(value);
    }
    return redactString(value);
  }

  if (
    typeof value === 'number'
    || typeof value === 'boolean'
    || typeof value === 'bigint'
  ) {
    return value;
  }

  if (value instanceof Date) {
    return value.toISOString();
  }

  if (Array.isArray(value)) {
    return value.map((item) => sanitizeValue(item, key, depth + 1));
  }

  if (value instanceof Error) {
    return {
      name: value.name,
      message: redactString(value.message),
      stack: process.env.NODE_ENV === 'production' ? undefined : redactString(value.stack ?? ''),
    };
  }

  if (typeof value === 'object') {
    const result: Record<string, unknown> = {};
    for (const [objectKey, objectValue] of Object.entries(value as Record<string, unknown>)) {
      if (isSensitiveKey(objectKey)) {
        result[objectKey] = '[REDACTED]';
        continue;
      }
      result[objectKey] = sanitizeValue(objectValue, objectKey, depth + 1);
    }
    return result;
  }

  return String(value);
}

function sanitizeMeta(meta: AppLogMeta): Record<string, unknown> {
  const requestId = meta.requestId ?? getRequestIdFromContext();
  const mergedMeta = requestId ? { ...meta, requestId } : meta;
  return sanitizeValue(mergedMeta) as Record<string, unknown>;
}

function formatTextLog(payload: Record<string, unknown>): string {
  const { ts, level, message, ...meta } = payload;
  const metaText = Object.entries(meta)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${typeof value === 'string' ? value : JSON.stringify(value)}`)
    .join(' ');

  const base = `${ts} ${String(level).toUpperCase()} ${message}`;
  return metaText ? `${base} ${metaText}` : base;
}

export function logMessage(level: AppLogLevel, message: string, meta: AppLogMeta = {}): void {
  if (!shouldLog(level)) return;

  const payload: Record<string, unknown> = {
    ts: new Date().toISOString(),
    level,
    message,
    ...sanitizeMeta(meta),
  };

  const stream = level === 'error' ? process.stderr : process.stdout;
  if (resolveLogFormat() === 'json') {
    stream.write(`${JSON.stringify(payload)}\n`);
    return;
  }
  stream.write(`${formatTextLog(payload)}\n`);
}

export function logDebug(message: string, meta: AppLogMeta = {}): void {
  logMessage('debug', message, meta);
}

export function logInfo(message: string, meta: AppLogMeta = {}): void {
  logMessage('info', message, meta);
}

export function logWarn(message: string, meta: AppLogMeta = {}): void {
  logMessage('warn', message, meta);
}

export function logError(message: string, meta: AppLogMeta = {}): void {
  logMessage('error', message, meta);
}
