import {
  BadRequestException,
  Body,
  Controller,
  GoneException,
  Get,
  Param,
  Post,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { PagesService } from './pages.service';

const MAX_FILE_BYTES = 200 * 1024 * 1024;

type FileFilterCb = (error: Error | null, accept: boolean) => void;

function mimeFilter(allowed: string[]) {
  return (_req: unknown, file: { mimetype: string }, cb: FileFilterCb) => {
    cb(null, allowed.includes(file.mimetype));
  };
}

@Controller('pages')
export class PagesController {
  constructor(private readonly pagesService: PagesService) {}

  @Post('upload/pdf')
  @UseInterceptors(FileInterceptor('file', {
    limits: { fileSize: MAX_FILE_BYTES },
    fileFilter: mimeFilter(['application/pdf', 'image/png', 'image/jpeg', 'image/webp']),
  }))
  async uploadPdf(
    @UploadedFile() file: { originalname: string; mimetype: string; buffer: Buffer } | undefined,
    @Body('bookId') bookId: string,
    @Body('chapterId') chapterId: string | undefined,
    @Body('language') language = 'auto',
    @Body('ocrMode') ocrMode: 'auto' | 'force' = 'auto',
  ) {
    if (!file) throw new BadRequestException({ message: 'Expected a PDF or image file', businessCode: 'INVALID_FILE_TYPE' });
    return this.pagesService.createFromPdf(
      bookId,
      file.buffer,
      language,
      chapterId,
      file.originalname,
      file.mimetype,
      ocrMode === 'force' ? 'force' : 'auto',
    );
  }


  @Post('upload/txt')
  @UseInterceptors(FileInterceptor('file', {
    limits: { fileSize: MAX_FILE_BYTES },
    fileFilter: mimeFilter(['text/plain', 'text/x-plain']),
  }))
  async uploadTxt(
    @UploadedFile() file: { buffer: Buffer } | undefined,
    @Body('bookId') bookId: string,
    @Body('chapterId') chapterId: string | undefined,
  ) {
    if (!file) throw new BadRequestException({ message: 'Expected a plain text file', businessCode: 'INVALID_FILE_TYPE' });
    return this.pagesService.createFromTxt(bookId, file.buffer, chapterId);
  }


  @Post('upload/epub')
  @UseInterceptors(FileInterceptor('file', {
    limits: { fileSize: MAX_FILE_BYTES },
    fileFilter: mimeFilter(['application/epub+zip']),
  }))
  async uploadEpub(
    @UploadedFile() file: { originalname: string; mimetype: string; buffer: Buffer } | undefined,
    @Body('bookId') bookId: string,
    @Body('chapterId') chapterId: string | undefined,
  ) {
    if (!file) throw new BadRequestException({ message: 'Expected an EPUB file', businessCode: 'INVALID_FILE_TYPE' });
    return this.pagesService.createFromEpub(
      bookId,
      file.buffer,
      chapterId,
      file.originalname,
      file.mimetype,
    );
  }


  @Get(':id/stream-translate')
  streamTranslate() {
    throw new GoneException('Deprecated endpoint. Use /events/book/:bookId.');
  }

  @Get('book/:bookId')
  findByBookId(@Param('bookId') bookId: string) {
    return this.pagesService.findByBookId(bookId);
  }

  @Get('chapter/:chapterId')
  findByChapterId(@Param('chapterId') chapterId: string) {
    return this.pagesService.findByChapterId(chapterId);
  }
}
