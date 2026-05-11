import { Injectable } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import IORedis from 'ioredis';
import { firstValueFrom, timeout, catchError } from 'rxjs';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';


export interface ServiceHealth {
  status: 'ok' | 'error';
  latencyMs: number;
  message?: string;

  activeModel?: string;

  models?: string[];

  modelCount?: number;
  provider?: string;
}


export interface HealthReport {
  status: 'ok' | 'degraded' | 'error';
  timestamp: string;
  services: {
    database: ServiceHealth;
    redis: ServiceHealth;
    ocr: ServiceHealth;
    llm: ServiceHealth;
  };
}


async function measure<T>(
  fn: () => Promise<T>,
  onOk: (result: T) => Omit<ServiceHealth, 'latencyMs'>,
): Promise<ServiceHealth> {
  const start = Date.now();
  try {
    const result = await fn();
    return { ...onOk(result), latencyMs: Date.now() - start };
  } catch (err: unknown) {
    return {
      status: 'error',
      latencyMs: Date.now() - start,
      message: err instanceof Error ? err.message : String(err),
    };
  }
}

@Injectable()
export class HealthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly httpService: HttpService,
    private readonly settingsService: SettingsService,
  ) {}

  async check(): Promise<HealthReport> {

    const [database, redis, ocr, llm] = await Promise.all([
      this.checkDatabase(),
      this.checkRedis(),
      this.checkOcr(),
      this.checkLlm(),
    ]);


    const statuses = [database, redis, ocr, llm].map((s) => s.status);
    const allOk = statuses.every((s) => s === 'ok');
    const allError = statuses.every((s) => s === 'error');

    return {
      status: allOk ? 'ok' : allError ? 'error' : 'degraded',
      timestamp: new Date().toISOString(),
      services: { database, redis, ocr, llm },
    };
  }


  private checkDatabase(): Promise<ServiceHealth> {
    return measure(
      () => this.prisma.$queryRawUnsafe<unknown[]>('SELECT 1'),
      () => ({ status: 'ok' }),
    );
  }


  private checkRedis(): Promise<ServiceHealth> {
    return measure(
      async () => {
        const client = new IORedis({
          host: process.env.REDIS_HOST ?? '127.0.0.1',
          port: Number(process.env.REDIS_PORT ?? 6379),
          maxRetriesPerRequest: 1,
          connectTimeout: 3000,
        });
        try {
          const pong = await client.ping();
          if (pong !== 'PONG') throw new Error(`Unexpected PING response: ${pong}`);
        } finally {
          client.disconnect();
        }
      },
      () => ({ status: 'ok' }),
    );
  }


  private checkOcr(): Promise<ServiceHealth> {
    const url = `${process.env.OCR_SERVICE_URL ?? 'http://127.0.0.1:8001'}/health`;
    return measure(
      () =>
        firstValueFrom(
          this.httpService.get<{ status: string }>(url).pipe(
            timeout(3000),
            catchError(() => {
              throw new Error('OCR service did not respond');
            }),
          ),
        ),
      (res) => ({
        status: res.data?.status === 'ok' ? 'ok' : 'error',
        message: res.data?.status !== 'ok' ? `Unexpected OCR status: ${res.data?.status}` : undefined,
      }),
    );
  }


  private async checkLlm(): Promise<ServiceHealth> {
    const { baseUrl, apiKey, model } = await this.settingsService.getEffectiveLlmConfig();

    return measure(
      () => this.settingsService.fetchModels(baseUrl, apiKey),
      (res) => {
        return {
          status: 'ok',
          provider: res.provider,
          activeModel: model,
          modelCount: res.models.length,
          models: res.models.slice(0, 5),
        };
      },
    );
  }
}
