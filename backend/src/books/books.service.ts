import { Injectable, NotFoundException } from '@nestjs/common';
import { Book } from '@prisma/client';
import epub, { type Chapter as EpubChapter } from 'epub-gen-memory';
import * as PDFKit from 'pdfkit';
import { promises as fs } from 'fs';
import * as fsSync from 'fs';
import * as path from 'path';
import { pathToFileURL } from 'url';
import { computeBookProgress } from '../common/book-progress';
import { imageMarkerRegex } from '../common/image-markers';
import { resolveStorageRoot } from '../common/storage-config';
import { PrismaService } from '../prisma/prisma.service';
import { CreateBookDto } from './dto/create-book.dto';
import { UpdateBookDto } from './dto/update-book.dto';

@Injectable()
export class BooksService {
  constructor(private readonly prisma: PrismaService) {}

  async create(dto: CreateBookDto): Promise<Book> {
    return this.prisma.book.create({
      data: {
        title: dto.title,
        sourceLang: dto.sourceLang,
        targetLang: dto.targetLang,
      },
    });
  }

  async findAll() {
    const books = await this.prisma.book.findMany({
      orderBy: { createdAt: 'desc' },
      include: {
        chapters: {
          select: { id: true, translationProgress: true },
          orderBy: { chapterNumber: 'asc' },
          take: 1,
        },
        pages: {
          select: { translationStatus: true },
        },
      },
    });
    const enriched = await Promise.all(
      books.map(async ({ chapters, pages, ...book }) => ({
        ...book,
        translationProgress: computeBookProgress(pages ?? []),
        chapterId: chapters[0]?.id ?? null,
        coverUrl: await this.resolveCoverUrl(book.id),
      })),
    );
    return enriched;
  }

  async findOne(id: string): Promise<Book> {
    const book = await this.prisma.book.findUnique({
      where: { id },
    });
    if (!book) {
      throw new NotFoundException(`Book(${id}) not found`);
    }
    return book;
  }

  async update(id: string, dto: UpdateBookDto): Promise<Book> {
    await this.findOne(id);
    return this.prisma.book.update({
      where: { id },
      data: dto,
    });
  }

  async downloadTxt(id: string): Promise<{ buffer: Buffer; filename: string }> {
    const book = await this.findOne(id);
    const pages = await this.prisma.page.findMany({
      where: { bookId: id, translationStatus: 'completed' },
      orderBy: { pageNumber: 'asc' },
      select: { targetText: true },
    });
    const content = pages
      .map((p) => this.stripMarkdown(p.targetText ?? ''))
      .filter((t) => t.trim())
      .join('\n\n');
    return { buffer: Buffer.from(content, 'utf-8'), filename: `${book.title}.txt` };
  }

  async downloadEpub(id: string): Promise<{ buffer: Buffer; filename: string }> {
    const book = await this.findOne(id);
    const chapters = await this.prisma.chapter.findMany({
      where: { bookId: id },
      orderBy: { chapterNumber: 'asc' },
      include: {
        pages: {
          where: { translationStatus: 'completed' },
          orderBy: { pageNumber: 'asc' },
          select: { sourceText: true, targetText: true },
        },
      },
    });

    const epubChapters: EpubChapter[] = chapters
      .filter((ch) => ch.pages.length > 0)
      .map((ch) => ({
        title: ch.title ?? `Chapter ${ch.chapterNumber}`,
        content: ch.pages
          .map((p) =>
            (p.targetText ?? p.sourceText ?? '')
              .split('\n\n')
              .filter((b) => b.trim())
              .map((raw) => {
                const b = raw.trim();
                const imageOnlyMatch = b.match(/^\[\[OB_IMAGE:([^\]|]+)(?:\|([^\]]*))?\]\]$/);
                if (imageOnlyMatch) {
                  const imageTag = this.buildImageTagFromMarker(id, imageOnlyMatch[1], imageOnlyMatch[2] ?? '');
                  return imageTag ? `<p>${imageTag}</p>` : '';
                }

                const headingMatch = b.match(/^(#{1,6})\s+([\s\S]+)$/);
                if (headingMatch) {
                  const level = headingMatch[1].length;
                  const content = this.markdownInlineToHtml(this.escapeHtml(headingMatch[2].trim()));
                  return `<h${level}>${content}</h${level}>`;
                }
                return `<p>${this.replaceImageMarkersInline(id, this.markdownInlineToHtml(this.escapeHtml(b)))}</p>`;
              })
              .join(''),
          )
          .join('<hr/>'),
      }));

    const buffer = await epub(
      { title: book.title, lang: book.targetLang, ignoreFailedDownloads: true },
      epubChapters,
    );
    return { buffer: Buffer.from(buffer), filename: `${book.title}.epub` };
  }

  async downloadPdf(id: string): Promise<{ buffer: Buffer; filename: string }> {
    const book = await this.findOne(id);
    const chapters = await this.prisma.chapter.findMany({
      where: { bookId: id },
      orderBy: { chapterNumber: 'asc' },
      include: {
        pages: {
          where: { translationStatus: 'completed' },
          orderBy: { pageNumber: 'asc' },
          select: { targetText: true },
        },
      },
    });

    const PdfDocument = PDFKit as unknown as new (options?: PDFKit.PDFDocumentOptions) => PDFKit.PDFDocument;
    const doc = new PdfDocument({
      autoFirstPage: false,
      size: 'A4',
      margin: 54,
      bufferPages: true,
      info: { Title: book.title },
    });
    const chunks: Buffer[] = [];
    doc.on('data', (chunk: Buffer) => chunks.push(chunk));
    const done = new Promise<Buffer>((resolve) => {
      doc.on('end', () => resolve(Buffer.concat(chunks)));
    });

    const font = this.resolvePdfFont();
    if (font) {
      doc.registerFont('Body', font.path, font.family);
      doc.font('Body');
    } else {
      doc.font('Helvetica');
    }

    doc.addPage();
    doc.fontSize(18).text(book.title, { align: 'center' });
    doc.moveDown(1.5);

    const chaptersWithPages = chapters.filter((chapter) => chapter.pages.length > 0);
    for (let index = 0; index < chaptersWithPages.length; index += 1) {
      const chapter = chaptersWithPages[index];
      doc.fontSize(14).text(chapter.title ?? `Chapter ${chapter.chapterNumber}`);
      doc.moveDown(0.6);
      doc.fontSize(11);
      for (const page of chapter.pages) {
        const blocks = this.stripMarkdown(page.targetText ?? '')
          .split(/\n{2,}/)
          .map((block) => block.trim())
          .filter(Boolean);
        for (const block of blocks) {
          doc.text(block, {
            align: 'left',
            lineGap: 5,
            paragraphGap: 8,
          });
        }
        doc.moveDown(0.5);
      }
      if (index < chaptersWithPages.length - 1) doc.addPage();
    }
    doc.end();
    return { buffer: await done, filename: `${book.title}.pdf` };
  }

  async readImageAsset(bookId: string, relativePath: string): Promise<{ buffer: Buffer; mimeType: string }> {
    await this.findOne(bookId);
    const safe = relativePath.replace(/^\/+/, '');
    if (!safe || safe.includes('..')) throw new NotFoundException('Asset not found');

    const isImageAsset = safe.startsWith('images/');
    const isCoverAsset = /^cover\.[a-z0-9]+$/i.test(safe);
    if (!isImageAsset && !isCoverAsset) throw new NotFoundException('Asset not found');

    const bookRoot = path.join(resolveStorageRoot(), bookId);
    const absolute = path.resolve(bookRoot, safe);
    const safePrefix = `${bookRoot}${path.sep}`;
    if (!absolute.startsWith(safePrefix)) throw new NotFoundException('Asset not found');

    const buffer = await fs.readFile(absolute);
    return { buffer, mimeType: this.mimeFromExt(path.extname(absolute)) };
  }

  async remove(id: string): Promise<Book> {
    await this.findOne(id);
    const deleted = await this.prisma.book.delete({
      where: { id },
    });
    await fs.rm(path.join(resolveStorageRoot(), id), { recursive: true, force: true }).catch(() => undefined);
    return deleted;
  }

  private replaceImageMarkersInline(bookId: string, text: string): string {
    return text.replace(imageMarkerRegex(), (_full, markerPath: string, alt: string | undefined) => {
      return this.buildImageTagFromMarker(bookId, markerPath, alt ?? '');
    });
  }

  private buildImageTagFromMarker(bookId: string, markerPath: string, alt: string): string {
    const safePath = markerPath.trim();
    if (!safePath) return '';
    const absolute = path.resolve(path.join(resolveStorageRoot(), bookId), safePath);
    const url = pathToFileURL(absolute).toString();
    return `<img src="${url}" alt="${this.escapeHtml(alt.trim() || 'illustration')}" />`;
  }

  private markdownInlineToHtml(escaped: string): string {
    return escaped
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/\*([^*]+)\*/g, '<em>$1</em>');
  }

  private stripMarkdown(text: string): string {
    return text
      .replace(/^#{1,6}\s+/gm, '')
      .replace(/\*\*([^*]+)\*\*/g, '$1')
      .replace(/\*([^*]+)\*/g, '$1');
  }

  private resolvePdfFont(): { path: string; family?: string } | null {
    const candidates: Array<{ path?: string; family?: string }> = [
      { path: process.env.PDF_FONT_PATH, family: process.env.PDF_FONT_FAMILY },
      { path: '/System/Library/Fonts/Supplemental/Arial Unicode.ttf' },
      { path: '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf' },
      { path: '/System/Library/Fonts/STHeiti Medium.ttc', family: 'STHeitiSC-Medium' },
      { path: '/System/Library/Fonts/Hiragino Sans GB.ttc', family: 'HiraginoSansGB-W3' },
      { path: '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc', family: 'NotoSansCJKsc-Regular' },
      { path: '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc', family: 'NotoSansCJKsc-Regular' },
    ];
    const found = candidates.find((candidate) => candidate.path && fsSync.existsSync(candidate.path));
    return found?.path ? { path: found.path, family: found.family } : null;
  }

  private escapeHtml(input: string): string {
    return input
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  private async resolveCoverUrl(bookId: string): Promise<string | null> {
    const bookDir = path.join(resolveStorageRoot(), bookId);
    const entries = await fs.readdir(bookDir).catch(() => []);
    const coverFile = entries.find((name) => /^cover\.(png|jpe?g|webp|gif|svg)$/i.test(name));
    if (coverFile) {
      return `/books/${bookId}/image-asset?path=${encodeURIComponent(coverFile)}`;
    }

    const imagesDir = path.join(bookDir, 'images');
    const imageEntries = await fs.readdir(imagesDir).catch(() => []);
    const fallback = imageEntries.find((name) => /\.(png|jpe?g|webp|gif|svg)$/i.test(name));
    if (!fallback) return null;
    return `/books/${bookId}/image-asset?path=${encodeURIComponent(`images/${fallback}`)}`;
  }

  private mimeFromExt(ext: string): string {
    switch (ext.toLowerCase()) {
      case '.png': return 'image/png';
      case '.jpg':
      case '.jpeg': return 'image/jpeg';
      case '.gif': return 'image/gif';
      case '.webp': return 'image/webp';
      case '.svg': return 'image/svg+xml';
      default: return 'application/octet-stream';
    }
  }
}
