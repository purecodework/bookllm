import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { Request, Response } from 'express';
import { logError, logWarn } from '../logging/app-logger';

type RequestWithId = Request & { requestId?: string };

interface ErrorResponse {
  code: number;
  businessCode?: string;
  requestId?: string;
  message: string;
  details?: unknown;
  path: string;
  timestamp: string;
}

@Catch()
export class HttpExceptionFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<RequestWithId>();

    let status: number;
    let message: string;
    let details: unknown;
    let businessCode: string | undefined;
    const requestId = request.requestId;

    const normalizeMessage = (value: unknown, fallback: string): string => {
      if (Array.isArray(value)) {
        const lines = value
          .map((v) => (typeof v === 'string' ? v.trim() : ''))
          .filter(Boolean);
        return lines.length ? lines.join('; ') : fallback;
      }
      if (typeof value === 'string' && value.trim()) return value;
      return fallback;
    };

    const defaultBusinessCode = (httpStatus: number): string => {
      switch (httpStatus) {
        case HttpStatus.BAD_REQUEST: return 'BAD_REQUEST';
        case HttpStatus.UNAUTHORIZED: return 'UNAUTHORIZED';
        case HttpStatus.FORBIDDEN: return 'FORBIDDEN';
        case HttpStatus.NOT_FOUND: return 'NOT_FOUND';
        case HttpStatus.CONFLICT: return 'CONFLICT';
        case HttpStatus.UNPROCESSABLE_ENTITY: return 'VALIDATION_ERROR';
        case HttpStatus.TOO_MANY_REQUESTS: return 'RATE_LIMITED';
        case HttpStatus.BAD_GATEWAY: return 'BAD_GATEWAY';
        case HttpStatus.SERVICE_UNAVAILABLE: return 'SERVICE_UNAVAILABLE';
        case HttpStatus.GATEWAY_TIMEOUT: return 'GATEWAY_TIMEOUT';
        default: return 'HTTP_ERROR';
      }
    };


    const multerCode = exception instanceof Error
      ? (exception as unknown as Record<string, unknown>)['code']
      : undefined;

    if (typeof multerCode === 'string' && multerCode.startsWith('LIMIT_')) {
      if (multerCode === 'LIMIT_FILE_SIZE') {
        status = HttpStatus.PAYLOAD_TOO_LARGE;
        message = 'File is too large. Maximum allowed size is 200 MB.';
        businessCode = 'FILE_TOO_LARGE';
      } else {
        status = HttpStatus.BAD_REQUEST;
        message = 'File upload rejected: upload limit exceeded.';
        businessCode = 'UPLOAD_LIMIT_EXCEEDED';
      }
    } else if (exception instanceof HttpException) {
      status = exception.getStatus();
      const body = exception.getResponse();
      if (typeof body === 'string') {
        message = body;
      } else if (typeof body === 'object' && body !== null) {
        const bodyObj = body as Record<string, unknown>;
        message = normalizeMessage(bodyObj.message, exception.message);
        details = bodyObj.errors ?? bodyObj.details;
        if (typeof bodyObj.businessCode === 'string' && bodyObj.businessCode.trim()) {
          businessCode = bodyObj.businessCode.trim();
        } else if (typeof bodyObj.errorCode === 'string' && bodyObj.errorCode.trim()) {
          businessCode = bodyObj.errorCode.trim();
        }
      } else {
        message = exception.message;
      }
      if (!businessCode) businessCode = defaultBusinessCode(status);
    } else {
      status = HttpStatus.INTERNAL_SERVER_ERROR;
      message = 'Internal server error';
      businessCode = 'INTERNAL_ERROR';
      if (exception instanceof Error) {
        details = process.env.NODE_ENV !== 'production' ? exception.stack : undefined;
      }
    }

    const logMeta = {
      requestId,
      businessCode,
      path: request.url,
      method: request.method,
      statusCode: status,
      details,
      error: exception instanceof Error ? exception : undefined,
    };
    if (status >= 500) {
      logError('http_exception', logMeta);
    } else {
      logWarn('http_exception', logMeta);
    }

    const body: ErrorResponse = {
      code: status,
      businessCode,
      requestId,
      message,
      details,
      path: request.url,
      timestamp: new Date().toISOString(),
    };

    response.status(status).json(body);
  }
}
