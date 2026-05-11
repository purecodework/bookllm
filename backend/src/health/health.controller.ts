import { Controller, Get, HttpCode, HttpStatus } from '@nestjs/common';
import { HealthService, HealthReport } from './health.service';

@Controller('health')
export class HealthController {
  constructor(private readonly healthService: HealthService) {}


  @Get()
  @HttpCode(HttpStatus.OK)
  async check(): Promise<HealthReport> {
    const report = await this.healthService.check();
    return report;
  }
}
