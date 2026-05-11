import { Injectable, OnModuleDestroy } from '@nestjs/common';
import IORedis from 'ioredis';
import { AppEvent, EventType } from '../events/events.types';

@Injectable()
export class RedisPubSubService implements OnModuleDestroy {
  private readonly pub: IORedis;

  constructor() {
    this.pub = new IORedis({
      host: process.env.REDIS_HOST ?? '127.0.0.1',
      port: Number(process.env.REDIS_PORT ?? 6379),
      maxRetriesPerRequest: null,
    });
  }

  async publish(channel: string, message: string): Promise<void> {
    await this.pub.publish(channel, message);
  }

  async getValue(key: string): Promise<string | null> {
    return this.pub.get(key);
  }

  async setValue(key: string, value: string, ttlSeconds?: number): Promise<void> {
    if (ttlSeconds && ttlSeconds > 0) {
      await this.pub.set(key, value, 'EX', ttlSeconds);
      return;
    }
    await this.pub.set(key, value);
  }

  createSubscriber(): IORedis {
    return new IORedis({
      host: process.env.REDIS_HOST ?? '127.0.0.1',
      port: Number(process.env.REDIS_PORT ?? 6379),
      maxRetriesPerRequest: null,
    });
  }

  bookEventChannel(bookId: string): string {
    return `events:book:${bookId}`;
  }

  booksEventChannel(): string {
    return 'events:books';
  }

  async publishBookEvent<K extends EventType>(
    bookId: string,
    type: K,
    payload: AppEvent<K>['payload'],
  ): Promise<void> {
    const message = JSON.stringify({ type, payload } satisfies AppEvent<K>);
    await this.publish(this.bookEventChannel(bookId), message);
    await this.publish(this.booksEventChannel(), message);
  }

  async onModuleDestroy(): Promise<void> {
    await this.pub.quit();
  }
}
