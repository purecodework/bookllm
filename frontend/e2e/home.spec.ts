import { test, expect } from '@playwright/test';

const API = 'http://localhost:3001';

async function createBook(request: import('@playwright/test').APIRequestContext, title: string) {
  const res = await request.post(`${API}/books`, {
    data: { title, sourceLang: 'en', targetLang: 'zh' },
  });
  return res.json() as Promise<{ id: string; title: string }>;
}


test('首页：标题正常渲染', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: '我的项目' })).toBeVisible();
});

test('首页："新建项目"按钮可见', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('link', { name: '新建项目' })).toBeVisible();
});

test('首页：无书时显示空状态', async ({ page, request }) => {
  const res = await request.get(`${API}/books`);
  const books: { id: string }[] = await res.json();
  test.skip(books.length > 0, '当前有书籍数据，跳过空状态测试');

  await page.goto('/');
  await expect(page.getByText('还没有项目')).toBeVisible();
  await expect(page.getByRole('link', { name: '上传第一本书' })).toBeVisible();
});

test('首页：有书时显示书籍卡片', async ({ page, request }) => {
  const book = await createBook(request, 'E2E-卡片测试');

  try {
    await page.goto('/');
    await expect(page.getByText('E2E-卡片测试')).toBeVisible({ timeout: 10000 });
  } finally {
    await request.delete(`${API}/books/${book.id}`);
  }
});


test('导航：点击"新建项目"跳转上传页', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('link', { name: '新建项目' }).click();
  await expect(page).toHaveURL('/upload');
  await expect(page.getByRole('heading', { name: '上传文档' })).toBeVisible();
});

test('导航：上传页可返回首页', async ({ page }) => {
  await page.goto('/upload');
  await page.getByRole('link', { name: '返回项目列表' }).click();
  await expect(page).toHaveURL('/');
});
