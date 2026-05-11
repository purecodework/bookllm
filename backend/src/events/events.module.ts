import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { QueueModule } from '../queue/queue.module';
import { RedisModule } from '../redis/redis.module';
import { EventsController } from './events.controller';

@Module({
  imports: [PrismaModule, RedisModule, QueueModule],
  controllers: [EventsController],
})
export class EventsModule {}
