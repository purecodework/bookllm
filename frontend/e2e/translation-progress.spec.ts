import { test, expect } from '@playwright/test';
import {
  API,
  cleanupBooksByPrefix,
  createBookWithPages,
} from './helpers';

const PREFIX = 'E2E-ETA';

test.beforeEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.afterEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.describe('Chapter progress API contract', () => {
  test('new chapter exposes progress, timing, and speed fields', async ({ request }) => {
    const { chapter } = await createBookWithPages(request, PREFIX, 'schema', 1);

    const res = await request.get(`${API}/chapters/${chapter.id}`);
    expect(res.status()).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;

    expect(body).toMatchObject({
      status: 'pending',
      translationProgress: 0,
      translationStartedAt: null,
      tokensPerSecond: null,
    });
  });

  test('chapter patch updates status and progress without inventing timing data', async ({ request }) => {
    const { chapter } = await createBookWithPages(request, PREFIX, 'patch', 1);

    const patch = await request.patch(`${API}/chapters/${chapter.id}`, {
      data: { status: 'processing', translationProgress: 42 },
    });
    expect(patch.status()).toBe(200);

    const res = await request.get(`${API}/chapters/${chapter.id}`);
    expect(res.status()).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;

    expect(body).toMatchObject({
      status: 'processing',
      translationProgress: 42,
      translationStartedAt: null,
      tokensPerSecond: null,
    });
  });
});
