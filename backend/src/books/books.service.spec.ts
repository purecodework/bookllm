import { NotFoundException } from '@nestjs/common';
import { BooksService } from './books.service';
import { type PrismaService } from '../prisma/prisma.service';


jest.mock('epub-gen-memory', () => ({
  default: jest.fn().mockResolvedValue(Buffer.from('fake-epub-bytes')),
}));

type PrismaMock = {
  book:    { create: jest.Mock; findMany: jest.Mock; findUnique: jest.Mock; update: jest.Mock; delete: jest.Mock };
  page:    { findMany: jest.Mock };
  chapter: { findMany: jest.Mock };
};

function makePrisma(): PrismaMock {
  return {
    book:    { create: jest.fn(), findMany: jest.fn(), findUnique: jest.fn(), update: jest.fn(), delete: jest.fn() },
    page:    { findMany: jest.fn() },
    chapter: { findMany: jest.fn() },
  };
}

describe('BooksService', () => {
  let service: BooksService;
  let prisma: PrismaMock;

  beforeEach(() => {
    prisma = makePrisma();
    service = new BooksService(prisma as unknown as PrismaService);
  });

  it('should create book via prisma', async () => {
    prisma.book.create.mockResolvedValue({
      id: 'book_1', title: '测试小说', sourceLang: 'zh', targetLang: 'en',
      status: 'draft', createdAt: new Date(), updatedAt: new Date(),
    });

    const result = await service.create({ title: '测试小说', sourceLang: 'zh', targetLang: 'en' });

    expect(prisma.book.create).toHaveBeenCalledTimes(1);
    expect(result.title).toBe('测试小说');
  });

  it('findAll aggregates translationProgress from all book pages', async () => {
    prisma.book.findMany.mockResolvedValue([
      { id: 'b1', title: 'demo', status: 'processing', sourceLang: 'en', targetLang: 'zh',
        createdAt: new Date(), updatedAt: new Date(),
        chapters: [{ id: 'ch1', translationProgress: 100 }],
        pages: [
          { translationStatus: 'completed' },
          { translationStatus: 'processing' },
          { translationStatus: 'pending' },
          { translationStatus: 'completed' },
        ] },
    ]);

    const list = await service.findAll();

    expect(list).toHaveLength(1);
    expect(list[0].translationProgress).toBe(50);
    expect(list[0].chapterId).toBe('ch1');

    expect((list[0] as Record<string, unknown>).chapters).toBeUndefined();
    expect((list[0] as Record<string, unknown>).pages).toBeUndefined();
  });

  it('findAll returns translationProgress=0 when no chapters', async () => {
    prisma.book.findMany.mockResolvedValue([
      { id: 'b1', title: 'demo', status: 'pending', sourceLang: 'en', targetLang: 'zh',
        createdAt: new Date(), updatedAt: new Date(), chapters: [], pages: [] },
    ]);

    const [book] = await service.findAll();

    expect(book.translationProgress).toBe(0);
    expect(book.chapterId).toBeNull();
  });

  it('should return one book when found', async () => {
    prisma.book.findUnique.mockResolvedValue({ id: 'book_1', title: 'demo' });
    const book = await service.findOne('book_1');
    expect(book.id).toBe('book_1');
  });

  it('should throw NotFoundException when book not found', async () => {
    prisma.book.findUnique.mockResolvedValue(null);
    await expect(service.findOne('missing')).rejects.toBeInstanceOf(NotFoundException);
  });

  it('should remove existing book', async () => {
    prisma.book.findUnique.mockResolvedValue({ id: 'book_1', title: 'demo' });
    prisma.book.delete.mockResolvedValue({ id: 'book_1', title: 'demo' });
    const result = await service.remove('book_1');
    expect(prisma.book.delete).toHaveBeenCalledWith({ where: { id: 'book_1' } });
    expect(result.id).toBe('book_1');
  });

  describe('downloadTxt', () => {
    const BOOK = { id: 'b1', title: 'My Book', sourceLang: 'en', targetLang: 'zh',
                   status: 'completed', createdAt: new Date(), updatedAt: new Date() };

    it('joins completed pages as plain text without page separators', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.page.findMany.mockResolvedValue([
        { targetText: 'Hello world.' },
        { targetText: 'Second paragraph.' },
      ]);

      const { buffer, filename } = await service.downloadTxt('b1');
      const text = buffer.toString('utf-8');

      expect(filename).toBe('My Book.txt');
      expect(text).toContain('Hello world.');
      expect(text).toContain('Second paragraph.');
      expect(text).not.toMatch(/第 \d+ 页/);
    });

    it('skips pages with empty targetText', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.page.findMany.mockResolvedValue([
        { targetText: 'Good text.' },
        { targetText: '' },
        { targetText: null },
      ]);

      const { buffer } = await service.downloadTxt('b1');
      const text = buffer.toString('utf-8');

      expect(text.trim()).toBe('Good text.');
    });

    it('returns empty buffer when no completed pages', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.page.findMany.mockResolvedValue([]);

      const { buffer } = await service.downloadTxt('b1');
      expect(buffer.length).toBe(0);
    });

    it('queries only completed pages', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.page.findMany.mockResolvedValue([]);

      await service.downloadTxt('b1');

      expect(prisma.page.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { bookId: 'b1', translationStatus: 'completed' },
          orderBy: { pageNumber: 'asc' },
        }),
      );
    });
  });

  describe('downloadEpub', () => {
    const BOOK = { id: 'b1', title: 'Epic Novel', sourceLang: 'en', targetLang: 'zh',
                   status: 'completed', createdAt: new Date(), updatedAt: new Date() };

    it('returns buffer and correct filename', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        { id: 'ch1', chapterNumber: 1, title: '第一章',
          pages: [{ targetText: '# Heading\n\nSome content.' }] },
      ]);

      const { buffer, filename } = await service.downloadEpub('b1');

      expect(filename).toBe('Epic Novel.epub');
      expect(Buffer.isBuffer(buffer)).toBe(true);
      expect(buffer.length).toBeGreaterThan(0);
    });

    it('calls epub with book title and target language', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        { id: 'ch1', chapterNumber: 1, title: null,
          pages: [{ targetText: 'content' }] },
      ]);

      const epubFn = jest.requireMock('epub-gen-memory').default as jest.Mock;
      epubFn.mockClear();

      await service.downloadEpub('b1');

      expect(epubFn).toHaveBeenCalledWith(
        expect.objectContaining({ title: 'Epic Novel', lang: 'zh' }),
        expect.any(Array),
      );
    });

    it('falls back to chapter number as title when title is null', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        { id: 'ch1', chapterNumber: 3, title: null,
          pages: [{ targetText: 'text' }] },
      ]);

      const epubFn = jest.requireMock('epub-gen-memory').default as jest.Mock;
      epubFn.mockClear();

      await service.downloadEpub('b1');

      const chapters = epubFn.mock.calls[0][1] as { title: string }[];
      expect(chapters[0].title).toBe('Chapter 3');
    });

    it('converts markdown headings to HTML in chapter content', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        { id: 'ch1', chapterNumber: 1, title: 'Ch1',
          pages: [{ targetText: '# H1\n\n## H2\n\nParagraph.' }] },
      ]);

      const epubFn = jest.requireMock('epub-gen-memory').default as jest.Mock;
      epubFn.mockClear();

      await service.downloadEpub('b1');

      const chapters = epubFn.mock.calls[0][1] as { content: string }[];
      expect(chapters[0].content).toContain('<h1>H1</h1>');
      expect(chapters[0].content).toContain('<h2>H2</h2>');
      expect(chapters[0].content).toContain('<p>Paragraph.</p>');
    });

    it('skips chapters with no completed pages', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        { id: 'ch1', chapterNumber: 1, title: 'Empty', pages: [] },
        { id: 'ch2', chapterNumber: 2, title: 'Full', pages: [{ targetText: 'text' }] },
      ]);

      const epubFn = jest.requireMock('epub-gen-memory').default as jest.Mock;
      epubFn.mockClear();

      await service.downloadEpub('b1');

      const chapters = epubFn.mock.calls[0][1] as { title: string }[];
      expect(chapters).toHaveLength(1);
      expect(chapters[0].title).toBe('Full');
    });

    it('converts image markers to img tags with local file URLs', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        {
          id: 'ch1',
          chapterNumber: 1,
          title: 'Ch1',
          pages: [{ sourceText: null, targetText: '[[OB_IMAGE:images/test.png|test]]' }],
        },
      ]);

      const epubFn = jest.requireMock('epub-gen-memory').default as jest.Mock;
      epubFn.mockClear();

      await service.downloadEpub('b1');

      const chapters = epubFn.mock.calls[0][1] as { content: string }[];
      expect(chapters[0].content).toContain('<img src="file://');
      expect(chapters[0].content).toContain('images/test.png');
    });
  });

  describe('downloadPdf', () => {
    const BOOK = { id: 'b1', title: 'Printable Book', sourceLang: 'en', targetLang: 'zh',
                   status: 'completed', createdAt: new Date(), updatedAt: new Date() };

    it('returns a PDF buffer without relying on browser print headers', async () => {
      prisma.book.findUnique.mockResolvedValue(BOOK);
      prisma.chapter.findMany.mockResolvedValue([
        { id: 'ch1', chapterNumber: 1, title: '第一章', pages: [{ targetText: '你好世界。' }] },
      ]);

      const { buffer, filename } = await service.downloadPdf('b1');

      expect(filename).toBe('Printable Book.pdf');
      expect(buffer.subarray(0, 4).toString('utf-8')).toBe('%PDF');
      expect(buffer.toString('latin1')).not.toContain('localhost');
    });
  });
});
