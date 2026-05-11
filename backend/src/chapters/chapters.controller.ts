import { Body, Controller, Delete, Get, HttpCode, HttpStatus, Param, Patch, Post } from '@nestjs/common';
import { ChaptersService } from './chapters.service';
import { TranslationControlService } from '../queue/translation-control.service';
import { CreateChapterDto } from './dto/create-chapter.dto';
import { UpdateChapterDto } from './dto/update-chapter.dto';

@Controller('chapters')
export class ChaptersController {
  constructor(
    private readonly chaptersService: ChaptersService,
    private readonly translationControl: TranslationControlService,
  ) {}

  @Post()
  create(@Body() dto: CreateChapterDto) {
    return this.chaptersService.create(dto);
  }

  @Get('book/:bookId')
  findByBookId(@Param('bookId') bookId: string) {
    return this.chaptersService.findByBookId(bookId);
  }


  @Get('queue-status')
  getQueueStatus() {
    return this.translationControl.getQueueStatus();
  }

  @Get(':id')
  findOne(@Param('id') id: string) {
    return this.chaptersService.findOne(id);
  }

  @Patch(':id')
  update(@Param('id') id: string, @Body() dto: UpdateChapterDto) {
    return this.chaptersService.update(id, dto);
  }

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.chaptersService.remove(id);
  }


  @Post('book/:bookId/translate')
  @HttpCode(HttpStatus.ACCEPTED)
  startBookTranslation(@Param('bookId') bookId: string) {
    return this.translationControl.startBookTranslation(bookId);
  }


  @Post(':id/translate')
  @HttpCode(HttpStatus.ACCEPTED)
  startTranslation(@Param('id') id: string) {
    return this.translationControl.startTranslation(id);
  }

  @Post(':id/pause-translation')
  pauseTranslation() {
    return this.translationControl.pauseTranslation();
  }

  @Post(':id/resume-translation')
  resumeTranslation() {
    return this.translationControl.resumeTranslation();
  }
}
