import { type NextFunction, type Request, type Response } from 'express';
import { logMessage } from '../logging/app-logger';
import { __internal, requestIdMiddleware } from './request-id.middleware';

jest.mock('../logging/app-logger', () => ({
  logMessage: jest.fn(),
}));

describe('requestIdMiddleware', () => {
  afterEach(() => {
    jest.clearAllMocks();
  });

  it('reuses incoming x-request-id and logs request completion', () => {
    const listeners = new Map<string, () => void>();
    const req = {
      headers: { 'x-request-id': 'client-req-12345' },
      method: 'GET',
      url: '/health',
      originalUrl: '/health',
    } as unknown as Request;

    const res = {
      statusCode: 200,
      setHeader: jest.fn(),
      on: jest.fn((event: string, callback: () => void) => {
        listeners.set(event, callback);
        return res;
      }),
    } as unknown as Response;

    const next: NextFunction = jest.fn();
    requestIdMiddleware(req, res, next);

    expect(next).toHaveBeenCalledTimes(1);
    expect(req.requestId).toBe('client-req-12345');
    expect(res.setHeader).toHaveBeenCalledWith('x-request-id', 'client-req-12345');

    listeners.get('finish')?.();

    expect(logMessage).toHaveBeenCalledWith(
      'info',
      'http_request',
      expect.objectContaining({
        requestId: 'client-req-12345',
        method: 'GET',
        path: '/health',
        statusCode: 200,
      }),
    );
  });

  it('generates request id when incoming value is invalid', () => {
    const req = {
      headers: { 'x-request-id': 'bad id with spaces' },
      method: 'POST',
      url: '/books',
      originalUrl: '/books',
    } as unknown as Request;
    const res = {
      statusCode: 201,
      setHeader: jest.fn(),
      on: jest.fn(),
    } as unknown as Response;
    const next: NextFunction = jest.fn();

    requestIdMiddleware(req, res, next);

    expect(next).toHaveBeenCalledTimes(1);
    expect(req.requestId).toMatch(/^[0-9a-f-]{36}$/i);
    expect(res.setHeader).toHaveBeenCalledWith('x-request-id', req.requestId);
  });

  it('normalizeRequestId returns null for unsupported values', () => {
    expect(__internal.normalizeRequestId('')).toBeNull();
    expect(__internal.normalizeRequestId('abc')).toBeNull();
    expect(__internal.normalizeRequestId('abc def')).toBeNull();
    expect(__internal.normalizeRequestId('valid-id_123456')).toBe('valid-id_123456');
  });
});
