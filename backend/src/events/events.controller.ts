import { Controller, Get, Header, MessageEvent, Param, Sse } from '@nestjs/common';
import { Observable, Subscriber } from 'rxjs';
import { PrismaService } from '../prisma/prisma.service';
import { RedisPubSubService } from '../redis/redis-pubsub.service';
import { TranslationQueueService } from '../queue/translation.queue';
import { computeBookProgress } from '../common/book-progress';
import { AppEvent } from './events.types';

@Controller('events')
export class EventsController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly redisPubSub: RedisPubSubService,
    private readonly queue: TranslationQueueService,
  ) {}

  @Get('book/:bookId')
  @Sse()
  @Header('X-Accel-Buffering', 'no')
  @Header('Cache-Control', 'no-cache')
  streamBook(@Param('bookId') bookId: string): Observable<MessageEvent> {
    return this.createSnapshotStream(
      this.redisPubSub.bookEventChannel(bookId),
      async (push) => {
        const [book, chapters, paused] = await Promise.all([
          this.prisma.book.findUnique({ where: { id: bookId } }),
          this.prisma.chapter.findMany({
            where: { bookId },
            orderBy: { chapterNumber: 'asc' },
            select: {
              id: true,
              status: true,
              translationProgress: true,
              tokensPerSecond: true,
              translationStartedAt: true,
            },
          }),
          this.queue.isPaused(),
        ]);

        if (!book) return false;

        push({ type: 'queue_state', payload: { bookId, isPaused: paused } });
        for (const chapter of chapters) {
          push({
            type: 'chapter_state',
            payload: {
              bookId,
              chapterId: chapter.id,
              status: chapter.status,
              translationProgress: chapter.translationProgress,
              tokensPerSecond: chapter.tokensPerSecond ?? null,
              translationStartedAt: chapter.translationStartedAt?.toISOString() ?? null,
            },
          });
        }
        const glossaryProgress = await this.prisma.settings.findUnique({
          where: { key: `translation.glossary.progress.${bookId}.${book.targetLang}` },
          select: { value: true },
        });
        if (glossaryProgress?.value) {
          try {
            const payload = JSON.parse(glossaryProgress.value) as AppEvent<'glossary_progress'>['payload'];
            if (payload.completedSections < payload.totalSections) {
              push({
                type: 'glossary_extracting',
                payload: { bookId, chapterId: '__book__', extracting: true },
              });
              push({ type: 'glossary_progress', payload });
            }
          } catch {

          }
        }
        return true;
      },
    );
  }

  @Get('books')
  @Sse()
  @Header('X-Accel-Buffering', 'no')
  @Header('Cache-Control', 'no-cache')
  streamBooks(): Observable<MessageEvent> {
    return this.createSnapshotStream(
      this.redisPubSub.booksEventChannel(),
      async (push) => {
        const books = await this.prisma.book.findMany({
          orderBy: { createdAt: 'desc' },
          include: {
            pages: {
              select: { translationStatus: true },
            },
          },
        });

        for (const book of books) {
          push({
            type: 'book_state',
            payload: {
              bookId: book.id,
              status: book.status,
              translationProgress: computeBookProgress(book.pages ?? []),
            },
          });
        }
        return true;
      },
    );
  }


  private createSnapshotStream(
    channel: string,
    loadSnapshot: (push: (event: AppEvent) => void) => Promise<boolean>,
  ): Observable<MessageEvent> {
    return new Observable((sub: Subscriber<MessageEvent>) => {
      let seq = 0;
      let snapshotReady = false;
      const pendingRawEvents: string[] = [];

      const push = (event: AppEvent): void => {
        sub.next({ id: String(++seq), data: event } as MessageEvent);
      };
      const pushRaw = (raw: string): void => {
        const event = this.parseRawEvent(raw);
        if (event) push(event);
      };

      const subscriber = this.redisPubSub.createSubscriber();
      subscriber.on('message', (_ch, raw) => {
        if (!snapshotReady) { pendingRawEvents.push(raw); return; }
        pushRaw(raw);
      });

      (async () => {
        await subscriber.subscribe(channel);
        const ok = await loadSnapshot(push);
        if (!ok) {
          sub.complete();
          await subscriber.quit();
          return;
        }
        snapshotReady = true;
        for (const raw of pendingRawEvents.splice(0)) pushRaw(raw);
      })().catch(async () => {
        sub.complete();
        await subscriber.quit();
      });

      return () => { void subscriber.quit(); };
    });
  }

  private parseRawEvent(raw: string): AppEvent | null {
    try {
      const parsed = JSON.parse(raw) as AppEvent;
      return parsed?.type && parsed.payload ? parsed : null;
    } catch {
      return null;
    }
  }
}
