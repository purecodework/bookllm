import { type MessageEvent } from '@nestjs/common';
import { EventEmitter } from 'events';
import { EventsController } from './events.controller';

function makeSubscriber() {
  const emitter = new EventEmitter() as EventEmitter & {
    subscribe: jest.Mock<Promise<void>, [string]>;
    quit: jest.Mock<Promise<void>, []>;
  };
  emitter.subscribe = jest.fn().mockResolvedValue(undefined);
  emitter.quit = jest.fn().mockResolvedValue(undefined);
  return emitter;
}

describe('EventsController', () => {
  it('emits object payloads for book SSE snapshots, not pre-stringified JSON', async () => {
    const subscriber = makeSubscriber();
    const controller = new EventsController(
      {
        book: { findUnique: jest.fn().mockResolvedValue({ id: 'book_1' }) },
        chapter: {
          findMany: jest.fn().mockResolvedValue([
            {
              id: 'chapter_1',
              status: 'processing',
              translationProgress: 25,
              tokensPerSecond: null,
              translationStartedAt: null,
            },
          ]),
        },
      } as never,
      {
        createSubscriber: jest.fn().mockReturnValue(subscriber),
        bookEventChannel: jest.fn().mockReturnValue('events:book:book_1'),
      } as never,
      { isPaused: jest.fn().mockResolvedValue(false) } as never,
    );

    const events: MessageEvent[] = [];
    const subscription = controller.streamBook('book_1').subscribe((event) => events.push(event));
    await new Promise((resolve) => setImmediate(resolve));

    expect(events[0].data).toEqual({
      type: 'queue_state',
      payload: { bookId: 'book_1', isPaused: false },
    });
    expect(typeof events[0].data).toBe('object');
    expect(events[1].data).toEqual({
      type: 'chapter_state',
      payload: {
        bookId: 'book_1',
        chapterId: 'chapter_1',
        status: 'processing',
        translationProgress: 25,
        tokensPerSecond: null,
        translationStartedAt: null,
      },
    });

    subscription.unsubscribe();
  });
});
