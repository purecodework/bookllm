import { HttpModule } from '@nestjs/axios';
import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { EpubParserService } from './epub-parser.service';
import { PagesController } from './pages.controller';
import { PagesService } from './pages.service';

@Module({
  imports: [HttpModule, PrismaModule],
  controllers: [PagesController],
  providers: [PagesService, EpubParserService],
  exports: [PagesService],
})
export class PagesModule {}
