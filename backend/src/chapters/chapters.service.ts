import {
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { logInfo } from '../common/logging/app-logger';
import { computeChapterProgress } from '../common/chapter-progress';
import { PrismaService } from '../prisma/prisma.service';
import { CreateChapterDto } from './dto/create-chapter.dto';
import { UpdateChapterDto } from './dto/update-chapter.dto';

@Injectable()
export class ChaptersService {
  constructor(private readonly prisma: PrismaService) {}

  async create(dto: CreateChapterDto) {
    return this.prisma.chapter.create({
      data: {
        bookId: dto.bookId,
        chapterNumber: dto.chapterNumber,
        title: dto.title,
      },
    });
  }

  async findByBookId(bookId: string) {
    return this.prisma.chapter.findMany({
      where: { bookId },
      orderBy: { chapterNumber: 'asc' },
      include: { _count: { select: { pages: true } } },
    });
  }

  async findOne(id: string) {
    const chapter = await this.prisma.chapter.findUnique({
      where: { id },
      include: {
        pages: { orderBy: { pageNumber: 'asc' } },
      },
    });
    if (!chapter) throw new NotFoundException(`Chapter ${id} not found`);
    return chapter;
  }

  async update(id: string, dto: UpdateChapterDto) {
    await this.findOne(id);
    return this.prisma.chapter.update({
      where: { id },
      data: {
        ...(dto.title !== undefined && { title: dto.title }),
        ...(dto.status !== undefined && { status: dto.status }),
        ...(dto.translationProgress !== undefined && {
          translationProgress: dto.translationProgress,
        }),
      },
    });
  }

  async remove(id: string) {
    await this.findOne(id);
    return this.prisma.chapter.delete({ where: { id } });
  }

  async findByBookAndNumber(bookId: string, chapterNumber: number) {
    const chapter = await this.prisma.chapter.findUnique({
      where: { bookId_chapterNumber: { bookId, chapterNumber } },
    });
    if (!chapter) throw new NotFoundException(`Chapter ${chapterNumber} not found in book ${bookId}`);
    return chapter;
  }


  async recalculateProgress(chapterId: string) {
    const [total, translated] = await Promise.all([
      this.prisma.page.count({ where: { chapterId } }),
      this.prisma.page.count({ where: { chapterId, translationStatus: 'completed' } }),
    ]);
    const { progress, status } = computeChapterProgress(translated, total);
    logInfo('chapter_progress_recalculated', {
      event: 'chapter_progress_recalculated',
      chapterId,
      progress,
      status,
    });
    return this.prisma.chapter.update({
      where: { id: chapterId },
      data: { translationProgress: progress, status },
    });
  }
}
