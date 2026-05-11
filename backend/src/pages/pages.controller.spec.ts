import { PagesController } from './pages.controller';
import { type PagesService } from './pages.service';

describe('PagesController', () => {
  let controller: PagesController;
  let service: jest.Mocked<Partial<PagesService>>;

  beforeEach(() => {
    service = {
      createFromPdf: jest.fn(),
      findByBookId: jest.fn(),
      findByChapterId: jest.fn(),
    };
    controller = new PagesController(service as unknown as PagesService);
  });

  it('should pass file buffer directly to createFromPdf (no disk write)', async () => {
    const fakeBuffer = Buffer.from('pdf-content');
    (service.createFromPdf as jest.Mock).mockResolvedValue([
      { id: 'p1', bookId: 'book_1', pageNumber: 1 },
    ]);

    const result = await controller.uploadPdf(
      { originalname: 'demo.pdf', mimetype: 'application/pdf', buffer: fakeBuffer },
      'book_1',
      'ch_1',
      'zh',
      'force',
    );

    expect(service.createFromPdf).toHaveBeenCalledTimes(1);
    const [bookId, bufferArg, lang, chapterId, nameArg, mimeArg, ocrModeArg] = (service.createFromPdf as jest.Mock).mock.calls[0];
    expect(bookId).toBe('book_1');
    expect(Buffer.isBuffer(bufferArg)).toBe(true);
    expect(lang).toBe('zh');
    expect(chapterId).toBe('ch_1');
    expect(nameArg).toBe('demo.pdf');
    expect(mimeArg).toBe('application/pdf');
    expect(ocrModeArg).toBe('force');
    expect(result[0].id).toBe('p1');
  });

  it('should delegate findByBookId to service', async () => {
    (service.findByBookId as jest.Mock).mockResolvedValue([
      { id: 'p1', bookId: 'book_1', pageNumber: 1 },
    ]);
    const result = await controller.findByBookId('book_1');
    expect(service.findByBookId).toHaveBeenCalledWith('book_1');
    expect(result[0].id).toBe('p1');
  });

  it('should delegate findByChapterId to service', async () => {
    (service.findByChapterId as jest.Mock).mockResolvedValue([
      { id: 'p1', chapterId: 'ch_1', pageNumber: 1 },
    ]);
    const result = await controller.findByChapterId('ch_1');
    expect(service.findByChapterId).toHaveBeenCalledWith('ch_1');
    expect(result[0].id).toBe('p1');
  });
});
