import { PagesService } from './pages.service';
import { type PrismaService } from '../prisma/prisma.service';
import { type HttpService } from '@nestjs/axios';
import { of } from 'rxjs';
import * as JSZip from 'jszip';
import { promises as fs } from 'fs';
import * as path from 'path';
import { EpubParserService } from './epub-parser.service';

const OCR_URL = process.env.OCR_SERVICE_URL ?? 'http://ocr-service:8001';

describe('PagesService', () => {
  let service: PagesService;
  let prisma: {
    $transaction: jest.Mock;
    page: { findMany: jest.Mock };
    book: { findUnique: jest.Mock };
    bookOriginalAsset: { findUnique: jest.Mock; upsert: jest.Mock };
  };
  let txMock: { page: { createMany: jest.Mock; findMany: jest.Mock } };
  let httpService: { post: jest.Mock };

  beforeEach(() => {
    txMock = { page: { createMany: jest.fn(), findMany: jest.fn() } };
    prisma = {
      $transaction: jest.fn(async (cb: (tx: typeof txMock) => unknown) => cb(txMock)),
      page: { findMany: jest.fn() },
      book: { findUnique: jest.fn().mockResolvedValue({ id: 'book_1', targetLang: 'zh' }) },
      bookOriginalAsset: { findUnique: jest.fn().mockResolvedValue(null), upsert: jest.fn() },
    };
    httpService = { post: jest.fn() };
    service = new PagesService(
      prisma as unknown as PrismaService,
      httpService as unknown as HttpService,
      new EpubParserService(),
    );
  });

  it('should create pages in a transaction with chapterId', async () => {
    txMock.page.findMany.mockResolvedValue([{ id: 'p1', bookId: 'book_1', pageNumber: 1 }]);

    await service.createBatch('book_1', [
      { pageNumber: 1, sourceText: '第一页' },
      { pageNumber: 2, sourceText: '第二页' },
    ], 'ch_1');

    expect(txMock.page.createMany).toHaveBeenCalledWith({
      data: [
        { bookId: 'book_1', chapterId: 'ch_1', pageNumber: 1, sourceText: '第一页', ocrStatus: 'completed' },
        { bookId: 'book_1', chapterId: 'ch_1', pageNumber: 2, sourceText: '第二页', ocrStatus: 'completed' },
      ],
      skipDuplicates: true,
    });
  });

  it('should call OCR service via multipart upload and persist pages', async () => {
    httpService.post.mockReturnValue(
      of({ data: { pages: [{ pageNumber: 1, text: 'OCR-1' }, { pageNumber: 2, text: 'OCR-2' }] } }),
    );
    const createBatchSpy = jest
      .spyOn(service, 'createBatch')
      .mockResolvedValue([{ id: 'p1', bookId: 'book_1', pageNumber: 1, chapterId: null } as never]);

    const fakeBuffer = Buffer.from('fake pdf bytes');
    const result = await service.createFromPdf('book_1', fakeBuffer, 'zh', 'ch_1');

    expect(httpService.post).toHaveBeenCalledWith(
      `${OCR_URL}/ocr/pdf/upload`,
      expect.any(Object),
      expect.objectContaining({ headers: expect.any(Object) }),
    );
    expect(createBatchSpy).toHaveBeenCalledWith(
      'book_1',
      [{ pageNumber: 1, sourceText: 'OCR-1' }, { pageNumber: 2, sourceText: 'OCR-2' }],
      'ch_1',
    );
    expect(result[0].id).toBe('p1');
  });

  it('should call image OCR endpoint for uploaded image files', async () => {
    httpService.post.mockReturnValue(
      of({ data: { pages: [{ pageNumber: 1, text: 'Image OCR text' }] } }),
    );
    const createBatchSpy = jest
      .spyOn(service, 'createBatch')
      .mockResolvedValue([{ id: 'p1', bookId: 'book_1', pageNumber: 1, chapterId: null } as never]);

    await service.createFromPdf(
      'book_1',
      Buffer.from('fake image bytes'),
      'en',
      'ch_1',
      'scan.png',
      'image/png',
    );

    expect(httpService.post).toHaveBeenCalledWith(
      `${OCR_URL}/ocr/image/upload`,
      expect.any(Object),
      expect.objectContaining({ headers: expect.any(Object) }),
    );
    expect(createBatchSpy).toHaveBeenCalledWith(
      'book_1',
      [{ pageNumber: 1, sourceText: 'Image OCR text' }],
      'ch_1',
    );
  });

  it('should return empty pages when OCR response has no pages', async () => {
    httpService.post.mockReturnValue(of({ data: { status: 'ok', pageCount: 0, pages: [] } }));
    const createBatchSpy = jest
      .spyOn(service, 'createBatch')
      .mockResolvedValue([]);

    await service.createFromPdf('book_1', Buffer.from('fake pdf'));

    expect(createBatchSpy).toHaveBeenCalledWith('book_1', [], undefined);
  });

  it('should return pages by book id ordered', async () => {
    prisma.page.findMany.mockResolvedValue([{ id: 'p1', bookId: 'book_1', pageNumber: 1 }]);
    const pages = await service.findByBookId('book_1');
    expect(prisma.page.findMany).toHaveBeenCalledWith({
      where: { bookId: 'book_1' },
      orderBy: { pageNumber: 'asc' },
    });
    expect(pages).toHaveLength(1);
  });

  it('createFromPdf should persist OCR image payload to local asset folder', async () => {
    const originalDir = process.env.ORIGINAL_ASSET_DIR;
    const tmpRoot = path.join('/private/tmp', `ob-pdf-assets-${Date.now()}`);
    process.env.ORIGINAL_ASSET_DIR = tmpRoot;

    try {
      httpService.post.mockReturnValue(
        of({
          data: {
            pages: [
              {
                pageNumber: 1,
                text: 'Text before\n\n[[OB_IMAGE:images/pdf-p1-img1.png|Page 1 image 1]]',
                images: [
                  {
                    relativePath: 'images/pdf-p1-img1.png',
                    ext: 'png',
                    dataBase64: Buffer.from([1, 2, 3, 4]).toString('base64'),
                  },
                ],
              },
            ],
          },
        }),
      );
      jest.spyOn(service, 'createBatch').mockResolvedValue([
        { id: 'p1', bookId: 'book_1', pageNumber: 1, chapterId: 'ch_1' } as never,
      ]);

      await service.createFromPdf('book_1', Buffer.from('pdf bytes /Subtype /Image'), 'auto', 'ch_1');

      const imagePath = path.join(tmpRoot, 'book_1', 'images', 'pdf-p1-img1.png');
      await expect(fs.stat(imagePath)).resolves.toBeDefined();
    } finally {
      process.env.ORIGINAL_ASSET_DIR = originalDir;
      await fs.rm(tmpRoot, { recursive: true, force: true }).catch(() => undefined);
    }
  });

  it('createFromEpub should inject image marker into source text', async () => {
    const zip = new JSZip();
    zip.file(
      'META-INF/container.xml',
      `<?xml version="1.0"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>`,
    );
    zip.file(
      'OEBPS/content.opf',
      `<?xml version="1.0"?>
      <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
        <manifest>
          <item id="chap1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          <item id="img1" href="images/test.png" media-type="image/png"/>
        </manifest>
        <spine><itemref idref="chap1"/></spine>
      </package>`,
    );
    zip.file(
      'OEBPS/chapter1.xhtml',
      `<html><body><h1>Chapter</h1>
        <p>This paragraph is long enough for parser acceptance and includes image below.</p>
        <img src="images/test.png" alt="cover image"/>
      </body></html>`,
    );
    zip.file('OEBPS/images/test.png', Buffer.from([137, 80, 78, 71]));
    const buffer = await zip.generateAsync({ type: 'nodebuffer' });

    const createBatchSpy = jest
      .spyOn(service, 'createBatch')
      .mockResolvedValue([{ id: 'p-epub', bookId: 'book_1', pageNumber: 1, chapterId: 'ch_1' } as never]);

    await service.createFromEpub('book_1', buffer, 'ch_1', 'image-test.epub', 'application/epub+zip');
    const pagesArg = createBatchSpy.mock.calls[0]?.[1];
    expect(pagesArg?.length).toBeGreaterThan(0);
    expect(pagesArg?.[0].sourceText).toContain('[[OB_IMAGE:images/');
  });
});
