import { test, expect } from '@playwright/test';
import {
  cleanupBooksByPrefix,
  createBookWithPages,
} from './helpers';

const PREFIX = 'E2E-Reader';

test.beforeEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.afterEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.describe('Theme preferences', () => {
  test('theme toggle persists across reloads', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('html')).toHaveClass(/dark/);

    await page.getByTitle('Switch to light mode').click();
    await expect(page.locator('html')).not.toHaveClass(/dark/);

    await page.reload();
    await expect(page.locator('html')).not.toHaveClass(/dark/);

    await page.getByTitle('Switch to dark mode').click();
    await expect(page.locator('html')).toHaveClass(/dark/);
  });
});

test.describe('Reader typography controls', () => {
  test('popover exposes font size and line-height controls and persists selection', async ({ page, request }) => {
    const { book } = await createBookWithPages(request, PREFIX, 'typography', 1);

    await page.goto(`/book/${book.id}`);
    await page.getByTitle('Typography Settings').click();

    await expect(page.getByText('Font Size')).toBeVisible();
    await expect(page.getByText('Line Height')).toBeVisible();
    await page.getByRole('button', { name: 'Large' }).click();

    const stored = await page.evaluate(() => localStorage.getItem('bookllm:reader-prefs'));
    expect(JSON.parse(stored!).fontSize).toBe('lg');
  });
});

test.describe('Reader split pane', () => {
  test('collapses and restores the source pane', async ({ page, request }) => {
    const { book } = await createBookWithPages(request, PREFIX, 'split-pane', 2);

    await page.goto(`/book/${book.id}`);

    await expect(page.locator('.cursor-col-resize').first()).toBeVisible();
    await page.getByTitle('Hide source').click();
    await expect(page.locator('.cursor-col-resize').first()).toBeHidden();
    await expect(page.getByTitle('Show source')).toBeVisible();

    await page.getByTitle('Show source').click();
    await expect(page.locator('.cursor-col-resize').first()).toBeVisible();
  });
});

test.describe('Reading resume state', () => {
  test('prompts below 98 percent and suppresses prompt when finished', async ({ page, request }) => {
    const { book, chapter, pages } = await createBookWithPages(request, PREFIX, 'resume', 3);

    await page.goto('/');
    await page.evaluate(
      ({ bookId, chapterId, pageId }) => {
        localStorage.setItem(
          `reading-state:${bookId}`,
          JSON.stringify({
            lastPosition: { chapterId, pageId },
            progress: 0.5,
            isFinished: false,
            updatedAt: '2026-01-01T00:00:00.000Z',
          }),
        );
      },
      { bookId: book.id, chapterId: chapter.id, pageId: pages[1].id },
    );

    await page.goto(`/book/${book.id}`);
    await expect(page.getByText('Continue from where you left off?')).toBeVisible();

    await page.goto('/');
    await page.evaluate(
      ({ bookId, chapterId, pageId }) => {
        localStorage.setItem(
          `reading-state:${bookId}`,
          JSON.stringify({
            lastPosition: { chapterId, pageId },
            progress: 0.985,
            isFinished: true,
            updatedAt: '2026-01-01T00:00:00.000Z',
          }),
        );
      },
      { bookId: book.id, chapterId: chapter.id, pageId: pages[2].id },
    );

    await page.goto(`/book/${book.id}`);
    await expect(page.getByText('Continue from where you left off?')).toBeHidden();
  });
});
