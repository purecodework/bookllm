import { HttpService } from '@nestjs/axios';
import {
  BadRequestException,
  Injectable,
  NotFoundException,
  UnprocessableEntityException,
} from '@nestjs/common';
import { Page } from '@prisma/client';
import { createHash } from 'crypto';
import * as FormData from 'form-data';
import { firstValueFrom } from 'rxjs';
import { promises as fs } from 'fs';
import * as JSZip from 'jszip';
import * as path from 'path';
import { PrismaService } from '../prisma/prisma.service';
import { resolveStorageRoot } from '../common/storage-config';
import { estimateTokens } from '../common/token-estimate';
import { EpubManifestItem, EpubParserService } from './epub-parser.service';

interface OcrPageItem {
  pageNumber: number;
  text: string;
  images?: OcrPageImage[];
}

interface OcrPageImage {
  relativePath: string;
  ext?: string;
  dataBase64: string;
  alt?: string;
}

interface OcrPdfResponse {
  status?: string;
  pageCount?: number;
  scannedPages?: number;
  pages?: OcrPageItem[];
}

@Injectable()
export class PagesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly httpService: HttpService,
    private readonly epubParser: EpubParserService,
  ) {}


  async createBatch(
    bookId: string,
    pages: Array<{ pageNumber: number; sourceText: string }>,
    chapterId?: string,
  ): Promise<Page[]> {
    if (pages.length === 0) return [];

    return this.prisma.$transaction(async (tx) => {
      await tx.page.createMany({
        data: pages.map((item) => ({
          bookId,
          chapterId: chapterId ?? null,
          pageNumber: item.pageNumber,
          sourceText: item.sourceText,
          ocrStatus: 'completed',
        })),
        skipDuplicates: true,
      });

      return tx.page.findMany({
        where: { bookId },
        orderBy: { pageNumber: 'asc' },
      });
    });
  }


  async createFromPdf(
    bookId: string,
    fileBuffer: Buffer,
    language = 'auto',
    chapterId?: string,
    fileName = 'upload.pdf',
    mimeType = 'application/pdf',
    ocrMode: 'auto' | 'force' = 'auto',
  ): Promise<Page[]> {
    const ocrUrl = process.env.OCR_SERVICE_URL ?? 'http://ocr-service:8001';
    const form = new FormData();
    const isPdf = mimeType === 'application/pdf';
    form.append('file', fileBuffer, { filename: fileName, contentType: mimeType });
    form.append('language', language);
    if (isPdf) {
      form.append('ocrMode', ocrMode);
    }

    const response = await firstValueFrom(
      this.httpService.post<OcrPdfResponse>(`${ocrUrl}${isPdf ? '/ocr/pdf/upload' : '/ocr/image/upload'}`, form, {
        headers: form.getHeaders(),
      }),
    );

    const payload = response.data;
    const firstPdfImageRel = await this.persistPdfImagesFromOcr(bookId, payload.pages ?? []);
    if (firstPdfImageRel) {
      await this.persistBookCoverFromStoredImage(bookId, firstPdfImageRel);
    }

    const normalizedPages = (payload.pages ?? [])
      .filter((p) => p.text && p.text.trim().length > 0)
      .map((p) => ({ pageNumber: p.pageNumber, sourceText: p.text.trim() }));
    const pages = await this.createBatch(bookId, normalizedPages, chapterId);
    await this.persistOriginalAssetIfHasImages({
      bookId,
      fileBuffer,
      fileName,
      mimeType,
      hasImages: this.pdfHasImages(fileBuffer),
    });
    return pages;
  }

  async findOne(id: string) {
    const p = await this.prisma.page.findUnique({ where: { id } });
    if (!p) {
      throw new NotFoundException({
        message: `Page ${id} not found`,
        businessCode: 'PAGE_NOT_FOUND',
      });
    }
    return p;
  }

  async findBookByPage(pageId: string) {
    const p = await this.prisma.page.findUnique({ where: { id: pageId }, include: { book: true } });
    if (!p) {
      throw new NotFoundException({
        message: `Page ${pageId} not found`,
        businessCode: 'PAGE_NOT_FOUND',
      });
    }
    return p.book;
  }

  async markProcessing(id: string) {
    return this.prisma.page.update({ where: { id }, data: { translationStatus: 'processing', targetText: null } });
  }

  async savePartial(id: string, text: string) {
    return this.prisma.page.update({ where: { id }, data: { targetText: text } });
  }

  async markCompleted(id: string, text: string) {
    return this.prisma.page.update({ where: { id }, data: { translationStatus: 'completed', targetText: text } });
  }

  async markFailed(id: string) {
    return this.prisma.page.update({ where: { id }, data: { translationStatus: 'failed' } });
  }


  async findByBookId(bookId: string): Promise<Page[]> {
    return this.prisma.page.findMany({
      where: { bookId },
      orderBy: { pageNumber: 'asc' },
    });
  }


  async findByChapterId(chapterId: string): Promise<Page[]> {
    return this.prisma.page.findMany({
      where: { chapterId },
      orderBy: { pageNumber: 'asc' },
    });
  }


  async createFromTxt(
    bookId: string,
    buffer: Buffer,
    chapterId?: string,
  ): Promise<Page[]> {
    const text = buffer.toString('utf-8').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const pageTexts = this.splitTextIntoPages(text);
    return this.createBatch(
      bookId,
      pageTexts.map((t, i) => ({ pageNumber: i + 1, sourceText: t })),
      chapterId,
    );
  }


  async createFromEpub(
    bookId: string,
    buffer: Buffer,
    chapterId?: string,
    fileName = 'upload.epub',
    mimeType = 'application/epub+zip',
  ): Promise<Page[]> {
    const zip = await JSZip.loadAsync(buffer);

    const containerXml = await zip.file('META-INF/container.xml')?.async('string');
    if (!containerXml) {
      throw new BadRequestException({
        message: 'Invalid EPUB: META-INF/container.xml not found',
        businessCode: 'EPUB_CONTAINER_XML_MISSING',
      });
    }

    const opfPathMatch = containerXml.match(/full-path="([^"]+\.opf)"/i);
    if (!opfPathMatch) {
      throw new BadRequestException({
        message: 'Invalid EPUB: OPF path not found in container.xml',
        businessCode: 'EPUB_OPF_PATH_MISSING',
      });
    }
    const opfPath = opfPathMatch[1];
    const opfDir = opfPath.includes('/') ? opfPath.slice(0, opfPath.lastIndexOf('/') + 1) : '';

    const opfXml = await zip.file(opfPath)?.async('string');
    if (!opfXml) {
      throw new BadRequestException({
        message: `Invalid EPUB: OPF file not found at ${opfPath}`,
        businessCode: 'EPUB_OPF_FILE_MISSING',
      });
    }

    const manifestItems = this.epubParser.parseOpfManifestItems(opfXml, opfDir);
    const manifest = Object.fromEntries(manifestItems.map((item) => [item.id, item.href]));
    const hasImages = this.epubParser.epubHasImages(opfXml);
    const spineIds = this.epubParser.parseOpfSpine(opfXml);
    const imageFileMap = hasImages
      ? await this.extractEpubImages(zip, bookId, manifestItems)
      : new Map<string, string>();
    if (hasImages) {
      await this.persistEpubCoverImage(bookId, opfXml, manifestItems, imageFileMap);
    }

    let pageNumber = 1;
    const allPages: Array<{ pageNumber: number; sourceText: string }> = [];

    for (const spineId of spineIds) {
      const href = manifest[spineId];
      if (!href) continue;
      const html = await zip.file(href)?.async('string');
      if (!html) continue;
      const text = this.epubParser.htmlToText(html, href, imageFileMap);
      if (text.length < 50) continue;

      for (const t of this.splitTextIntoPages(text)) {
        allPages.push({ pageNumber: pageNumber++, sourceText: t });
      }
    }

    if (allPages.length === 0) {
      throw new UnprocessableEntityException({
        message: 'EPUB contains no readable content',
        businessCode: 'EPUB_NO_READABLE_CONTENT',
      });
    }

    const pages = await this.createBatch(bookId, allPages, chapterId);
    await this.persistOriginalAssetIfHasImages({
      bookId,
      fileBuffer: buffer,
      fileName,
      mimeType,
      hasImages,
    });
    return pages;
  }

  private splitTextIntoPages(text: string): string[] {
    const TARGET_TOKENS = 800;
    const paragraphs = text.split(/\n{2,}/);
    const pages: string[] = [];
    let buffer = '';
    let bufferTokens = 0;

    for (const para of paragraphs) {
      const trimmed = para.trim();
      if (!trimmed) continue;

      const paraTokens = estimateTokens(trimmed);
      const candidateTokens = bufferTokens + (buffer ? 1 : 0) + paraTokens;

      if (candidateTokens > TARGET_TOKENS && buffer) {
        pages.push(buffer);
        buffer = trimmed;
        bufferTokens = paraTokens;
      } else {
        buffer = buffer ? `${buffer}\n\n${trimmed}` : trimmed;
        bufferTokens = candidateTokens;
      }
    }

    if (buffer.trim()) pages.push(buffer);
    return pages;
  }

  private async extractEpubImages(
    zip: JSZip,
    bookId: string,
    manifestItems: EpubManifestItem[],
  ): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    const imageItems = manifestItems.filter((item) => item.mediaType.toLowerCase().startsWith('image/'));
    if (imageItems.length === 0) return out;

    const dir = path.join(resolveStorageRoot(), bookId, 'images');
    await fs.mkdir(dir, { recursive: true });

    for (const item of imageItems) {
      const file = zip.file(item.href);
      if (!file) continue;
      const bytes = await file.async('nodebuffer');
      const ext = this.extFrom(item.mediaType, item.href);
      const digest = createHash('sha1').update(bytes).digest('hex').slice(0, 12);
      const base = this.safeFileName(path.basename(item.href, path.extname(item.href)));
      const storedName = `${digest}-${base}${ext}`;
      const abs = path.join(dir, storedName);
      await fs.writeFile(abs, bytes);
      out.set(item.href, `images/${storedName}`);
    }
    return out;
  }

  private async persistPdfImagesFromOcr(
    bookId: string,
    pages: OcrPageItem[],
  ): Promise<string | null> {
    const baseDir = path.resolve(resolveStorageRoot(), bookId);
    const safePrefix = `${baseDir}${path.sep}`;
    let firstSavedImageRel: string | null = null;

    for (let pageIndex = 0; pageIndex < pages.length; pageIndex += 1) {
      const pageImages = pages[pageIndex].images ?? [];
      for (let imageIndex = 0; imageIndex < pageImages.length; imageIndex += 1) {
        const item = pageImages[imageIndex];
        if (!item?.dataBase64) continue;

        const fallbackRel = `images/pdf-p${pageIndex + 1}-img${imageIndex + 1}.${(item.ext ?? 'png').toLowerCase()}`;
        const rel = (item.relativePath || fallbackRel).replace(/^\/+/, '');
        if (rel.includes('..')) continue;

        const abs = path.resolve(baseDir, rel);
        if (!abs.startsWith(safePrefix)) continue;
        await fs.mkdir(path.dirname(abs), { recursive: true });
        await fs.writeFile(abs, Buffer.from(item.dataBase64, 'base64'));
        if (!firstSavedImageRel) {
          firstSavedImageRel = rel;
        }
      }
    }
    return firstSavedImageRel;
  }

  private async persistEpubCoverImage(
    bookId: string,
    opfXml: string,
    manifestItems: EpubManifestItem[],
    imageFileMap: Map<string, string>,
  ): Promise<void> {
    const coverHref = this.epubParser.pickEpubCoverHref(opfXml, manifestItems);
    const fallbackHref = manifestItems.find((item) => item.mediaType.toLowerCase().startsWith('image/'))?.href;
    const chosenHref = coverHref ?? fallbackHref;
    if (!chosenHref) return;

    const stored = imageFileMap.get(chosenHref);
    if (!stored) return;
    await this.persistBookCoverFromStoredImage(bookId, stored);
  }

  private async persistBookCoverFromStoredImage(bookId: string, relativePath: string): Promise<void> {
    const safe = relativePath.replace(/^\/+/, '');
    if (!safe || safe.includes('..')) return;

    const baseDir = path.resolve(resolveStorageRoot(), bookId);
    const safePrefix = `${baseDir}${path.sep}`;
    const sourceAbs = path.resolve(baseDir, safe);
    if (!sourceAbs.startsWith(safePrefix)) return;

    const ext = path.extname(sourceAbs).toLowerCase() || '.png';
    const targetAbs = path.join(baseDir, `cover${ext}`);
    await fs.mkdir(baseDir, { recursive: true });
    await fs.copyFile(sourceAbs, targetAbs);

    const entries = await fs.readdir(baseDir).catch(() => []);
    await Promise.all(
      entries
        .filter((name) => /^cover\./i.test(name) && path.join(baseDir, name) !== targetAbs)
        .map((name) => fs.unlink(path.join(baseDir, name)).catch(() => undefined)),
    );
  }

  private pdfHasImages(buffer: Buffer): boolean {
    return /\/Subtype\s*\/Image\b/.test(buffer.toString('latin1'));
  }

  private safeFileName(name: string): string {
    return name.replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 120) || 'original.bin';
  }

  private extFrom(mimeType: string, fileName: string): string {
    const fromName = path.extname(fileName || '').toLowerCase();
    if (fromName) return fromName;
    if (mimeType === 'application/pdf') return '.pdf';
    if (mimeType === 'application/epub+zip') return '.epub';
    if (mimeType.startsWith('text/')) return '.txt';
    return '.bin';
  }

  private async persistOriginalAssetIfHasImages(input: {
    bookId: string;
    fileBuffer: Buffer;
    fileName: string;
    mimeType: string;
    hasImages: boolean;
  }): Promise<void> {
    if (!input.hasImages) return;

    const root = resolveStorageRoot();
    const dir = path.join(root, input.bookId);
    await fs.mkdir(dir, { recursive: true });

    const ext = this.extFrom(input.mimeType, input.fileName);
    const safeName = this.safeFileName(path.basename(input.fileName, path.extname(input.fileName)));
    const storedName = `${Date.now()}-${safeName}${ext}`;
    const filePath = path.join(dir, storedName);
    const sha256 = createHash('sha256').update(input.fileBuffer).digest('hex');

    const existing = await this.prisma.bookOriginalAsset.findUnique({
      where: { bookId: input.bookId },
    });

    await fs.writeFile(filePath, input.fileBuffer);

    await this.prisma.bookOriginalAsset.upsert({
      where: { bookId: input.bookId },
      create: {
        bookId: input.bookId,
        filePath,
        fileName: input.fileName,
        mimeType: input.mimeType,
        fileSize: input.fileBuffer.length,
        sha256,
        hasImages: true,
      },
      update: {
        filePath,
        fileName: input.fileName,
        mimeType: input.mimeType,
        fileSize: input.fileBuffer.length,
        sha256,
        hasImages: true,
      },
    });

    if (existing?.filePath && existing.filePath !== filePath) {
      await fs.unlink(existing.filePath).catch(() => undefined);
    }
  }
}
