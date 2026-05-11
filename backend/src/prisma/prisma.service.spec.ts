import { type INestApplication } from '@nestjs/common';
import { PrismaService } from './prisma.service';

describe('PrismaService', () => {
  it('onModuleInit should not call $connect (lazy connection strategy)', async () => {
    const service = new PrismaService();
    const connectSpy = jest.spyOn(service, '$connect').mockResolvedValue();

    await service.onModuleInit();

    expect(connectSpy).not.toHaveBeenCalled();
  });

  it('should disconnect on module destroy', async () => {
    const service = new PrismaService();
    const disconnectSpy = jest.spyOn(service, '$disconnect').mockResolvedValue();

    await service.onModuleDestroy();
    expect(disconnectSpy).toHaveBeenCalledTimes(1);
  });

  it('should register beforeExit hook and close app', async () => {
    const service = new PrismaService();
    const appMock = { close: jest.fn().mockResolvedValue(undefined) } as unknown as INestApplication;
    const onSpy = jest.spyOn(service, '$on').mockImplementation(((_eventType: string, callback: () => void) => {
      callback();
      return service;
    }) as never);

    service.enableShutdownHooks(appMock);
    expect(onSpy).toHaveBeenCalledTimes(1);
  });
});
