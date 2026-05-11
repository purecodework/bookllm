import 'reflect-metadata';
import { config } from 'dotenv';
config();
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { HttpExceptionFilter } from './common/filters/http-exception.filter';
import { logInfo } from './common/logging/app-logger';
import { requestIdMiddleware } from './common/middleware/request-id.middleware';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);

  app.useGlobalFilters(new HttpExceptionFilter());
  app.use(requestIdMiddleware);


  const corsOriginEnv = process.env.CORS_ORIGIN ?? '';
  const corsOrigin: string | RegExp | (string | RegExp)[] =
    corsOriginEnv === '*'
      ? '*'
      : corsOriginEnv
        ? corsOriginEnv.split(',').map((o) => o.trim()).filter(Boolean)
        : /^http:\/\/localhost(:\d+)?$/;
  app.enableCors({ origin: corsOrigin, credentials: true });

  const port = Number(process.env.PORT ?? 3001);
  await app.listen(port);
  logInfo('server_started', {
    event: 'bootstrap',
    port,
    url: `http://localhost:${port}`,
    healthUrl: `http://localhost:${port}/health`,
  });
}

void bootstrap();
