import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { GlossaryService } from './glossary.service';
import { TranslationChunkerService } from './translation-chunker.service';
import { LlmModule } from '../llm/llm.module';

@Module({
  imports: [LlmModule, PrismaModule],
  providers: [TranslationChunkerService, GlossaryService],
  exports: [TranslationChunkerService, GlossaryService],
})
export class TranslationModule {}
