import { Body, Controller, Delete, Get, Header, Param, Post, Query, Res, StreamableFile } from '@nestjs/common';
import type { Response } from 'express';
import { CreateBookDto } from './dto/create-book.dto';
import { BooksService } from './books.service';

@Controller('books')
export class BooksController {
  constructor(private readonly booksService: BooksService) {}

  @Post()
  create(@Body() dto: CreateBookDto): ReturnType<BooksService['create']> {
    return this.booksService.create(dto);
  }

  @Get()
  findAll(): ReturnType<BooksService['findAll']> {
    return this.booksService.findAll();
  }

  @Get(':id')
  findOne(@Param('id') id: string): ReturnType<BooksService['findOne']> {
    return this.booksService.findOne(id);
  }

  @Get(':id/download/txt')
  @Header('Content-Type', 'text/plain; charset=utf-8')
  async downloadTxt(
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<StreamableFile> {
    const { buffer, filename } = await this.booksService.downloadTxt(id);
    res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`);
    return new StreamableFile(buffer);
  }

  @Get(':id/download/epub')
  @Header('Content-Type', 'application/epub+zip')
  async downloadEpub(
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<StreamableFile> {
    const { buffer, filename } = await this.booksService.downloadEpub(id);
    res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`);
    return new StreamableFile(buffer);
  }

  @Get(':id/download/pdf')
  @Header('Content-Type', 'application/pdf')
  async downloadPdf(
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<StreamableFile> {
    const { buffer, filename } = await this.booksService.downloadPdf(id);
    res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`);
    return new StreamableFile(buffer);
  }

  @Get(':id/image-asset')
  async imageAsset(
    @Param('id') id: string,
    @Query('path') imagePath: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<StreamableFile> {
    const { buffer, mimeType } = await this.booksService.readImageAsset(id, imagePath);
    res.setHeader('Content-Type', mimeType);
    res.setHeader('Cache-Control', 'public, max-age=86400');
    return new StreamableFile(buffer);
  }

  @Delete(':id')
  remove(@Param('id') id: string): ReturnType<BooksService['remove']> {
    return this.booksService.remove(id);
  }
}
