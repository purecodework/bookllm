import { StreamableFile } from '@nestjs/common';
import { BooksController } from './books.controller';
import { type BooksService } from './books.service';
import type { Response } from 'express';

jest.mock('epub-gen-memory', () => ({
  default: jest.fn().mockResolvedValue(Buffer.from('fake-epub-bytes')),
}));

function makeService(): jest.Mocked<BooksService> {
  return {
    create:       jest.fn(),
    findAll:      jest.fn(),
    findOne:      jest.fn(),
    update:       jest.fn(),
    remove:       jest.fn(),
    downloadTxt:  jest.fn(),
    downloadEpub: jest.fn(),
    downloadPdf:  jest.fn(),
    readImageAsset: jest.fn(),
  } as unknown as jest.Mocked<BooksService>;
}

function makeRes(): jest.Mocked<Pick<Response, 'setHeader'>> {
  return { setHeader: jest.fn() };
}

describe('BooksController', () => {
  let controller: BooksController;
  let service: jest.Mocked<BooksService>;

  beforeEach(() => {
    service = makeService();
    controller = new BooksController(service);
  });

  it('should delegate create to service', async () => {
    service.create.mockResolvedValue({ id: 'b1', status: 'draft', title: 'A',
      sourceLang: 'zh', targetLang: 'en' } as never);
    const result = await controller.create({ title: 'A', sourceLang: 'zh', targetLang: 'en' });
    expect(service.create).toHaveBeenCalledTimes(1);
    expect(result.status).toBe('draft');
  });

  it('should delegate findAll to service', () => {
    service.findAll.mockResolvedValue([{ id: '1', title: 'demo', status: 'draft' }] as never);
    const result = controller.findAll();
    expect(service.findAll).toHaveBeenCalledTimes(1);
    return expect(result).resolves.toEqual([{ id: '1', title: 'demo', status: 'draft' }]);
  });

  it('should delegate findOne to service', async () => {
    service.findOne.mockResolvedValue({ id: '1', title: 'demo', status: 'draft' } as never);
    const result = await controller.findOne('1');
    expect(service.findOne).toHaveBeenCalledWith('1');
    expect(result.id).toBe('1');
  });

  it('should delegate remove to service', async () => {
    service.remove.mockResolvedValue({ id: '1', title: 'demo', status: 'draft' } as never);
    const result = await controller.remove('1');
    expect(service.remove).toHaveBeenCalledWith('1');
    expect(result.id).toBe('1');
  });

  describe('GET :id/download/txt', () => {
    it('calls service.downloadTxt with book id', async () => {
      service.downloadTxt.mockResolvedValue({ buffer: Buffer.from('hello'), filename: 'A.txt' });
      const res = makeRes();
      await controller.downloadTxt('b1', res as unknown as Response);
      expect(service.downloadTxt).toHaveBeenCalledWith('b1');
    });

    it('sets Content-Disposition attachment header with encoded filename', async () => {
      service.downloadTxt.mockResolvedValue({ buffer: Buffer.from('text'), filename: '我的书.txt' });
      const res = makeRes();
      await controller.downloadTxt('b1', res as unknown as Response);
      expect(res.setHeader).toHaveBeenCalledWith(
        'Content-Disposition',
        expect.stringMatching(/attachment/),
      );

      const [, value] = res.setHeader.mock.calls[0] as [string, string];
      expect(value).toContain(encodeURIComponent('我的书.txt'));
    });

    it('returns a StreamableFile', async () => {
      service.downloadTxt.mockResolvedValue({ buffer: Buffer.from('content'), filename: 'A.txt' });
      const res = makeRes();
      const result = await controller.downloadTxt('b1', res as unknown as Response);
      expect(result).toBeInstanceOf(StreamableFile);
    });
  });

  describe('GET :id/download/epub', () => {
    it('calls service.downloadEpub with book id', async () => {
      service.downloadEpub.mockResolvedValue({ buffer: Buffer.from('epub'), filename: 'A.epub' });
      const res = makeRes();
      await controller.downloadEpub('b1', res as unknown as Response);
      expect(service.downloadEpub).toHaveBeenCalledWith('b1');
    });

    it('sets Content-Disposition attachment header', async () => {
      service.downloadEpub.mockResolvedValue({ buffer: Buffer.from('epub'), filename: 'My Novel.epub' });
      const res = makeRes();
      await controller.downloadEpub('b1', res as unknown as Response);
      const [, value] = res.setHeader.mock.calls[0] as [string, string];
      expect(value).toContain('attachment');
      expect(value).toContain(encodeURIComponent('My Novel.epub'));
    });

    it('returns a StreamableFile', async () => {
      service.downloadEpub.mockResolvedValue({ buffer: Buffer.from('epub'), filename: 'A.epub' });
      const res = makeRes();
      const result = await controller.downloadEpub('b1', res as unknown as Response);
      expect(result).toBeInstanceOf(StreamableFile);
    });
  });

  describe('GET :id/download/pdf', () => {
    it('calls service.downloadPdf with book id and returns a StreamableFile', async () => {
      service.downloadPdf.mockResolvedValue({ buffer: Buffer.from('%PDF'), filename: 'A.pdf' });
      const res = makeRes();
      const result = await controller.downloadPdf('b1', res as unknown as Response);
      expect(service.downloadPdf).toHaveBeenCalledWith('b1');
      expect(res.setHeader).toHaveBeenCalledWith(
        'Content-Disposition',
        expect.stringContaining(encodeURIComponent('A.pdf')),
      );
      expect(result).toBeInstanceOf(StreamableFile);
    });
  });
});
