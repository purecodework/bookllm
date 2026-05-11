import { Injectable } from '@nestjs/common';
import { Queue } from 'bullmq';

export const TRANSLATION_QUEUE = Symbol('TRANSLATION_QUEUE');


export interface TranslateChunkJobData {
  pageId: string;
  chapterId: string;
  bookId: string;
  chunkIndex: number;
  totalChunks: number;
  chunkText: string;
  contextTail: string;
  chapterTitle?: string;
  pageNumber?: number;
  sourceLang: string;
  targetLang: string;

  glossary?: unknown;

  stylePrompt?: string;
}


export interface TranslatePageJobData {
  pageId: string;
  chapterId: string;
  bookId: string;
  sourceLang: string;
  targetLang: string;
  chapterTitle?: string;
  pageNumber?: number;

  previousPageTail?: string;
}

@Injectable()
export class TranslationQueueService {
  constructor(private readonly queue: Queue) {}


  async enqueuePage(data: TranslatePageJobData): Promise<string> {
    const job = await this.queue.add('translate-page', data, {
      jobId: `page-${data.pageId}`,
      attempts: 3,
      backoff: { type: 'exponential', delay: 2000 },
    });
    return job.id ?? '';
  }

  async drain(): Promise<void> {
    await this.queue.drain();
  }

  async pause(): Promise<void> {
    await this.queue.pause();
  }

  async resume(): Promise<void> {
    await this.queue.resume();
  }

  async isPaused(): Promise<boolean> {
    return this.queue.isPaused();
  }
}
