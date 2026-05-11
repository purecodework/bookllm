import { Module } from '@nestjs/common';
import { HttpModule } from '@nestjs/axios';
import { ReviewService } from './review.service';

@Module({
  imports: [HttpModule],
  providers: [ReviewService],
  exports: [ReviewService],
})
export class ReviewModule {}
