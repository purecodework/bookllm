import { AsyncLocalStorage } from 'node:async_hooks';

interface RequestContextStore {
  requestId?: string;
}

const requestContextStorage = new AsyncLocalStorage<RequestContextStore>();

export function runWithRequestContext<T>(
  context: RequestContextStore,
  callback: () => T,
): T {
  return requestContextStorage.run(context, callback);
}

export function getRequestIdFromContext(): string | undefined {
  return requestContextStorage.getStore()?.requestId;
}
