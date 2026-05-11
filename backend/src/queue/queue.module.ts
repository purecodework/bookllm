import { Module } from '@nestjs/common';
import { Queue } from 'bullmq';
import IORedis from 'ioredis';
import { TRANSLATION_QUEUE, TranslationQueueService } from './translation.queue';
import { TranslationControlService } from './translation-control.service';
import { TranslationWorker } from './translation.worker';
import { TranslationModule } from '../translation/translation.module';
import { RedisModule } from '../redis/redis.module';
import { PrismaModule } from '../prisma/prisma.module';
import { ReviewModule } from '../review/review.module';

@Module({
  imports: [
    PrismaModule,
    TranslationModule,
    RedisModule,
    ReviewModule,
  ],
  providers: [
    {
      provide: TRANSLATION_QUEUE,
      useFactory: () => {
        const connection = new IORedis({
          host: process.env.REDIS_HOST ?? '127.0.0.1',
          port: Number(process.env.REDIS_PORT ?? 6379),
          maxRetriesPerRequest: null,
        });
        return new Queue('translation-jobs', { connection });
      },
    },
    {
      provide: TranslationQueueService,
      useFactory: (queue: Queue) => new TranslationQueueService(queue),
      inject: [TRANSLATION_QUEUE],
    },
    TranslationWorker,
    TranslationControlService,
  ],
  exports: [TranslationQueueService, TranslationControlService],
})
export class QueueModule {}
