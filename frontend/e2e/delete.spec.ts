import { test, expect, type Page, type APIRequestContext } from '@playwright/test';

const API = 'http://localhost:3001';


function uid(label: string) {
  return `E2E-${label}-${Date.now()}`;
}

async function createBook(request: APIRequestContext, title: string) {
  const res = await request.post(`${API}/books`, {
    data: { title, sourceLang: 'en', targetLang: 'zh' },
  });
  return res.json() as Promise<{ id: string; title: string }>;
}


async function cleanupE2EBooks(request: APIRequestContext) {
  const res = await request.get(`${API}/books`);
  const books: { id: string; title: string }[] = await res.json();
  await Promise.all(
    books.filter((b) => b.title.startsWith('E2E-')).map((b) => request.delete(`${API}/books/${b.id}`)),
  );
}


async function clickDeleteBtn(page: Page, title: string) {
  const panel = page.locator('[role="tabpanel"][data-state="active"]');
  const card = panel.locator('a[href^="/book/"]').filter({ hasText: title }).locator('..');
  await card.getByTestId('delete-book-btn').evaluate((el: HTMLElement) => el.click());
}


test.beforeEach(async ({ request }) => {
  await cleanupE2EBooks(request);
});


test('删除：点击垃圾桶弹出确认 Dialog', async ({ page, request }) => {
  const title = uid('Dialog');
  const book = await createBook(request, title);

  try {
    await page.goto('/');

    await clickDeleteBtn(page, title);

    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText('确认删除')).toBeVisible();
    await expect(dialog.getByText(title, { exact: false })).toBeVisible();
  } finally {
    await request.delete(`${API}/books/${book.id}`);
  }
});

test('删除：点击取消，Dialog 关闭，书仍在列表', async ({ page, request }) => {
  const title = uid('取消');
  const book = await createBook(request, title);

  try {
    await page.goto('/');
    await clickDeleteBtn(page, title);

    await page.getByRole('button', { name: '取消' }).click();

    await expect(page.getByRole('dialog')).not.toBeVisible();
    await expect(page.getByText(title)).toBeVisible();
  } finally {
    await request.delete(`${API}/books/${book.id}`);
  }
});

test('删除：点击确认，书从列表消失', async ({ page, request }) => {
  const title = uid('确认');
  await createBook(request, title);

  await page.goto('/');
  await clickDeleteBtn(page, title);
  await page.getByRole('button', { name: '删除' }).click();


  await expect(page.getByText(title)).not.toBeVisible();
});

test('删除：确认后 API 书记录已不存在（404）', async ({ page, request }) => {
  const title = uid('API');
  const book = await createBook(request, title);

  await page.goto('/');
  await clickDeleteBtn(page, title);
  await page.getByRole('button', { name: '删除' }).click();
  await expect(page.getByText(title)).not.toBeVisible();

  const res = await request.get(`${API}/books/${book.id}`);
  expect(res.status()).toBe(404);
});
