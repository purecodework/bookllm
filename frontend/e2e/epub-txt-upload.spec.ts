import * as fs from 'fs';
import * as path from 'path';
import { test, expect, type APIRequestContext } from '@playwright/test';

const API = 'http://localhost:3001';
const TEST_FILES = path.resolve(__dirname, '../../test-files');


function uid(label: string) {
  return `E2E-Upload-${label}-${Date.now()}`;
}

async function createBook(
  request: APIRequestContext,
  title: string,
  sourceLang = 'en',
  targetLang = 'zh',
) {
  const res = await request.post(`${API}/books`, {
    data: { title, sourceLang, targetLang },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<{ id: string; title: string }>;
}

async function cleanupE2EBooks(request: APIRequestContext) {
  const res = await request.get(`${API}/books`);
  const books: { id: string; title: string }[] = await res.json();
  await Promise.all(
    books
      .filter((b) => b.title.startsWith('E2E-Upload-'))
      .map((b) => request.delete(`${API}/books/${b.id}`)),
  );
}


test.describe('EPUB 上传流程', () => {
  test.beforeEach(async ({ request }) => {
    await cleanupE2EBooks(request);
  });

  test('上传 EPUB → 单一章节，所有页面有原文', async ({ request }) => {
    const book = await createBook(request, uid('epub'));


    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    const chapter = await chapterRes.json() as { id: string };

    const epubBuffer = fs.readFileSync(path.join(TEST_FILES, 'llm-test.epub'));
    const uploadRes = await request.post(`${API}/pages/upload/epub`, {
      multipart: {
        file: { name: 'llm-test.epub', mimeType: 'application/epub+zip', buffer: epubBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });

    expect(uploadRes.status()).toBe(201);


    const chaptersRes = await request.get(`${API}/chapters/book/${book.id}`);
    const chapters: { id: string; status: string; _count: { pages: number } }[] =
      await chaptersRes.json();
    expect(chapters).toHaveLength(1);
    expect(chapters[0].status).toBe('pending');
    expect(chapters[0]._count.pages).toBeGreaterThan(0);


    const pagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    const pages: { sourceText: string | null; ocrStatus: string }[] = await pagesRes.json();
    expect(pages.length).toBeGreaterThan(0);
    expect(pages.every((p) => p.ocrStatus === 'completed')).toBe(true);
    expect(pages.some((p) => p.sourceText && p.sourceText.trim().length > 0)).toBe(true);

    await request.delete(`${API}/books/${book.id}`);
  });

  test('EPUB 章节可触发翻译（enqueuedPages > 0）', async ({ request }) => {
    const book = await createBook(request, uid('epub-translate'));

    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    const chapter = await chapterRes.json() as { id: string };

    const epubBuffer = fs.readFileSync(path.join(TEST_FILES, 'llm-test.epub'));
    await request.post(`${API}/pages/upload/epub`, {
      multipart: {
        file: { name: 'llm-test.epub', mimeType: 'application/epub+zip', buffer: epubBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });

    const translateRes = await request.post(`${API}/chapters/${chapter.id}/translate`);
    expect(translateRes.status()).toBe(202);

    const { enqueuedPages } = await translateRes.json() as { enqueuedPages: number };
    expect(enqueuedPages).toBeGreaterThan(0);

    await request.delete(`${API}/books/${book.id}`);
  });

  test('EPUB 下载端点返回正确 Content-Type', async ({ request }) => {

    const booksRes = await request.get(`${API}/books`);
    const books: { id: string; status: string }[] = await booksRes.json();
    const done = books.find((b) => b.status === 'completed');
    test.skip(!done, '无已完成的书，跳过 EPUB 下载内容测试');

    const res = await request.get(`${API}/books/${done!.id}/download/epub`);
    expect(res.status()).toBe(200);
    expect(res.headers()['content-type']).toContain('epub');
    expect(res.headers()['content-disposition']).toContain('attachment');


    const body = await res.body();
    expect(body[0]).toBe(0x50);
    expect(body[1]).toBe(0x4b);
  });

  test('无内容 EPUB 下载不返回 500', async ({ request }) => {
    const book = await createBook(request, uid('epub-empty-dl'));

    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    const chapter = await chapterRes.json() as { id: string };

    const epubBuffer = fs.readFileSync(path.join(TEST_FILES, 'llm-test.epub'));
    await request.post(`${API}/pages/upload/epub`, {
      multipart: {
        file: { name: 'llm-test.epub', mimeType: 'application/epub+zip', buffer: epubBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });

    const res = await request.get(`${API}/books/${book.id}/download/epub`);
    expect(res.status()).not.toBe(500);

    await request.delete(`${API}/books/${book.id}`);
  });
});


test.describe('TXT 上传流程', () => {
  test.beforeEach(async ({ request }) => {
    await cleanupE2EBooks(request);
  });

  test('上传 TXT → 创建章节和页面', async ({ request }) => {
    const book = await createBook(request, uid('txt'));


    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    const chapter = await chapterRes.json() as { id: string };

    const txtBuffer = fs.readFileSync(path.join(TEST_FILES, 'llm-test.txt'));
    const uploadRes = await request.post(`${API}/pages/upload/txt`, {
      multipart: {
        file: { name: 'llm-test.txt', mimeType: 'text/plain', buffer: txtBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });

    expect(uploadRes.status()).toBe(201);


    const pagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    const pages: { sourceText: string | null; ocrStatus: string }[] = await pagesRes.json();
    expect(pages.length).toBeGreaterThan(0);
    expect(pages.every((p) => p.ocrStatus === 'completed')).toBe(true);
    expect(pages.some((p) => p.sourceText && p.sourceText.trim().length > 0)).toBe(true);

    await request.delete(`${API}/books/${book.id}`);
  });

  test('TXT 章节可触发翻译（enqueuedPages > 0）', async ({ request }) => {
    const book = await createBook(request, uid('txt-translate'));

    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    const chapter = await chapterRes.json() as { id: string };

    const txtBuffer = fs.readFileSync(path.join(TEST_FILES, 'llm-test.txt'));
    await request.post(`${API}/pages/upload/txt`, {
      multipart: {
        file: { name: 'llm-test.txt', mimeType: 'text/plain', buffer: txtBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });

    const translateRes = await request.post(`${API}/chapters/${chapter.id}/translate`);
    expect(translateRes.status()).toBe(202);

    const { enqueuedPages } = await translateRes.json() as { enqueuedPages: number };
    expect(enqueuedPages).toBeGreaterThan(0);

    await request.delete(`${API}/books/${book.id}`);
  });

  test('TXT 下载端点返回正确 Content-Type', async ({ request }) => {
    const booksRes = await request.get(`${API}/books`);
    const books: { id: string; status: string }[] = await booksRes.json();
    const done = books.find((b) => b.status === 'completed');
    test.skip(!done, '无已完成的书，跳过 TXT 下载内容测试');

    const res = await request.get(`${API}/books/${done!.id}/download/txt`);
    expect(res.status()).toBe(200);
    expect(res.headers()['content-type']).toContain('text/plain');
    expect(res.headers()['content-disposition']).toContain('attachment');

    const text = await res.text();
    expect(text.trim().length).toBeGreaterThan(0);
  });

  test('TXT 下载内容不含页码标识符', async ({ request }) => {
    const booksRes = await request.get(`${API}/books`);
    const books: { id: string; status: string }[] = await booksRes.json();
    const done = books.find((b) => b.status === 'completed');
    test.skip(!done, '无已完成的书，跳过内容格式测试');

    const res = await request.get(`${API}/books/${done!.id}/download/txt`);
    const text = await res.text();
    expect(text).not.toMatch(/第 \d+ 页/);
    expect(text).not.toMatch(/--- \d+ ---/);
  });
});


test.describe('EPUB 阅读器 UI', () => {
  test('上传 EPUB 后阅读器显示"开始翻译"按钮', async ({ page, request }) => {
    const book = await createBook(request, uid('epub-ui'));

    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    const chapter = await chapterRes.json() as { id: string };

    const epubBuffer = fs.readFileSync(path.join(TEST_FILES, 'llm-test.epub'));
    await request.post(`${API}/pages/upload/epub`, {
      multipart: {
        file: { name: 'llm-test.epub', mimeType: 'application/epub+zip', buffer: epubBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });

    try {
      await page.goto(`/book/${book.id}`);
      await page.waitForLoadState('networkidle');
      await expect(page.getByRole('button', { name: '开始翻译' })).toBeVisible({ timeout: 5000 });
    } finally {
      await request.delete(`${API}/books/${book.id}`);
    }
  });
});
