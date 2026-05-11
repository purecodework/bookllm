import { INestApplication, Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  async onModuleInit(): Promise<void> {


  }

  async onModuleDestroy(): Promise<void> {

    await this.$disconnect();
  }

  enableShutdownHooks(app: INestApplication): void {

    this.$on('beforeExit' as never, async () => {
      await app.close();
    });
  }
}
