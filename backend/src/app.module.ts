import { Module } from '@nestjs/common';
import { BooksModule } from './books/books.module';
import { ChaptersModule } from './chapters/chapters.module';
import { EventsModule } from './events/events.module';
import { HealthModule } from './health/health.module';
import { LlmModule } from './llm/llm.module';
import { PagesModule } from './pages/pages.module';
import { PrismaModule } from './prisma/prisma.module';
import { QueueModule } from './queue/queue.module';
import { SettingsModule } from './settings/settings.module';
import { TranslationModule } from './translation/translation.module';

@Module({
  imports: [PrismaModule, SettingsModule, BooksModule, ChaptersModule, PagesModule, QueueModule, LlmModule, HealthModule, TranslationModule, EventsModule],
})
export class AppModule {}
