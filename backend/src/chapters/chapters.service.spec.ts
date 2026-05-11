import { NotFoundException } from '@nestjs/common';
import { ChaptersService } from './chapters.service';
import { type PrismaService } from '../prisma/prisma.service';

jest.mock('../common/logging/app-logger', () => ({
  logInfo: jest.fn(),
  logWarn: jest.fn(),
  logError: jest.fn(),
}));

function makePrismaMock() {
  return {
    chapter: {
      create: jest.fn(),
      findMany: jest.fn(),
      findUnique: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
    },
    page: {
      count: jest.fn(),
    },
  };
}

function makeChapter(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: 'ch_1',
    bookId: 'book_1',
    chapterNumber: 1,
    title: '第一章',
    status: 'pending',
    translationProgress: 0,
    createdAt: new Date('2026-01-01'),
    updatedAt: new Date('2026-01-01'),
    ...overrides,
  };
}

describe('ChaptersService', () => {
  let service: ChaptersService;
  let prisma: ReturnType<typeof makePrismaMock>;

  beforeEach(() => {
    prisma = makePrismaMock();
    service = new ChaptersService(prisma as unknown as PrismaService);
  });

  describe('create', () => {
    it('calls prisma.chapter.create and returns the created chapter', async () => {
      const chapter = makeChapter();
      prisma.chapter.create.mockResolvedValue(chapter);

      const result = await service.create({
        bookId: 'book_1',
        chapterNumber: 1,
        title: '第一章',
      });

      expect(prisma.chapter.create).toHaveBeenCalledWith({
        data: { bookId: 'book_1', chapterNumber: 1, title: '第一章' },
      });
      expect(result.id).toBe('ch_1');
    });

    it('accepts undefined title (no title provided)', async () => {
      prisma.chapter.create.mockResolvedValue(makeChapter({ title: undefined }));

      await service.create({ bookId: 'book_1', chapterNumber: 1 });

      expect(prisma.chapter.create).toHaveBeenCalledWith({
        data: { bookId: 'book_1', chapterNumber: 1, title: undefined },
      });
    });
  });

  describe('findByBookId', () => {
    it('returns chapters ordered by chapterNumber ascending', async () => {
      const chapters = [makeChapter({ chapterNumber: 1 }), makeChapter({ id: 'ch_2', chapterNumber: 2 })];
      prisma.chapter.findMany.mockResolvedValue(chapters);

      const result = await service.findByBookId('book_1');

      expect(prisma.chapter.findMany).toHaveBeenCalledWith({
        where: { bookId: 'book_1' },
        orderBy: { chapterNumber: 'asc' },
        include: { _count: { select: { pages: true } } },
      });
      expect(result).toHaveLength(2);
    });
  });

  describe('findOne', () => {
    it('returns chapter with pages when found', async () => {
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());

      const result = await service.findOne('ch_1');

      expect(result.id).toBe('ch_1');
      expect(prisma.chapter.findUnique).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        include: { pages: { orderBy: { pageNumber: 'asc' } } },
      });
    });

    it('throws NotFoundException when chapter is not found', async () => {
      prisma.chapter.findUnique.mockResolvedValue(null);

      await expect(service.findOne('missing')).rejects.toBeInstanceOf(NotFoundException);
    });
  });

  describe('update', () => {
    it('updates status and translationProgress', async () => {
      const updated = makeChapter({ status: 'processing', translationProgress: 50 });
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.chapter.update.mockResolvedValue(updated);

      const result = await service.update('ch_1', { status: 'processing', translationProgress: 50 });

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { status: 'processing', translationProgress: 50 },
      });
      expect(result.status).toBe('processing');
    });

    it('throws NotFoundException when target does not exist', async () => {
      prisma.chapter.findUnique.mockResolvedValue(null);

      await expect(service.update('missing', { status: 'processing' })).rejects.toBeInstanceOf(
        NotFoundException,
      );
    });

    it('omits unset fields from update data (sparse update)', async () => {
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.chapter.update.mockResolvedValue(makeChapter({ title: '新标题' }));

      await service.update('ch_1', { title: '新标题' });

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { title: '新标题' },
      });
    });
  });

  describe('remove', () => {
    it('deletes an existing chapter', async () => {
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.chapter.delete.mockResolvedValue(makeChapter());

      await service.remove('ch_1');

      expect(prisma.chapter.delete).toHaveBeenCalledWith({ where: { id: 'ch_1' } });
    });

    it('throws NotFoundException when target does not exist', async () => {
      prisma.chapter.findUnique.mockResolvedValue(null);

      await expect(service.remove('missing')).rejects.toBeInstanceOf(NotFoundException);
    });
  });

  describe('recalculateProgress', () => {
    it('sets progress to 100 and status to completed when all pages are translated', async () => {
      prisma.page.count
        .mockResolvedValueOnce(5)
        .mockResolvedValueOnce(5);
      prisma.chapter.update.mockResolvedValue(makeChapter({ translationProgress: 100, status: 'completed' }));

      const result = await service.recalculateProgress('ch_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 100, status: 'completed' },
      });
      expect(result.translationProgress).toBe(100);
    });

    it('sets mid-range progress and processing status when partially translated', async () => {
      prisma.page.count
        .mockResolvedValueOnce(4)
        .mockResolvedValueOnce(2);
      prisma.chapter.update.mockResolvedValue(makeChapter({ translationProgress: 50, status: 'processing' }));

      await service.recalculateProgress('ch_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 50, status: 'processing' },
      });
    });

    it('sets progress to 0 and status to pending when there are no pages', async () => {
      prisma.page.count.mockResolvedValue(0);
      prisma.chapter.update.mockResolvedValue(makeChapter());

      await service.recalculateProgress('ch_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 0, status: 'pending' },
      });
    });

    it('sets status to pending when no pages are translated', async () => {
      prisma.page.count
        .mockResolvedValueOnce(3)
        .mockResolvedValueOnce(0);
      prisma.chapter.update.mockResolvedValue(makeChapter());

      await service.recalculateProgress('ch_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 0, status: 'pending' },
      });
    });
  });
});
