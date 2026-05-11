import { TranslationQueueService } from './translation.queue';
import { type Queue } from 'bullmq';

function makeQueueMock() {
  return {
    add: jest.fn(),
  };
}

describe('TranslationQueueService', () => {
  let service: TranslationQueueService;
  let queue: ReturnType<typeof makeQueueMock>;

  beforeEach(() => {
    queue = makeQueueMock();
    service = new TranslationQueueService(queue as unknown as Queue);
  });

  describe('enqueuePage', () => {
    it('calls queue.add and returns the jobId', async () => {
      queue.add.mockResolvedValue({ id: 'page-job-1' });

      const id = await service.enqueuePage({
        pageId: 'page_1',
        chapterId: 'ch_1',
        bookId: 'book_1',
        sourceLang: 'zh',
        targetLang: 'en',
      });

      expect(queue.add).toHaveBeenCalledWith(
        'translate-page',
        expect.objectContaining({ pageId: 'page_1' }),
        expect.objectContaining({ jobId: 'page-page_1', attempts: 3 }),
      );
      expect(id).toBe('page-job-1');
    });

    it('jobId does not contain colons (BullMQ restriction)', async () => {
      queue.add.mockResolvedValue({ id: 'x' });
      await service.enqueuePage({
        pageId: 'page_1', chapterId: 'ch_1', bookId: 'book_1',
        sourceLang: 'zh', targetLang: 'en',
      });
      const [, , opts] = queue.add.mock.calls[0] as [string, unknown, { jobId: string }];
      expect(opts.jobId).not.toContain(':');
    });

    it('falls back to empty string when id is undefined', async () => {
      queue.add.mockResolvedValue({ id: undefined });
      const id = await service.enqueuePage({
        pageId: 'page_2', chapterId: 'ch_1', bookId: 'book_1',
        sourceLang: 'zh', targetLang: 'en',
      });
      expect(id).toBe('');
    });
  });
});
