import { renderHook, act, waitFor } from '@testing-library/react';
import { useBookEvents } from '@/hooks/use-book-events';
import type { UsageStats } from '@/hooks/use-book-events';

type BookEvent = {
  type: string;
  payload: Record<string, unknown>;
};

class FakeEventSource {
  static instances: FakeEventSource[] = [];
  onmessage: ((event: MessageEvent<string>) => void) | null = null;
  close = jest.fn();

  constructor(public readonly url: string) {
    FakeEventSource.instances.push(this);
  }

  emit(event: BookEvent) {
    this.onmessage?.({ data: JSON.stringify(event) } as MessageEvent<string>);
  }
}

type HookProps = {
  hasProcessing: boolean;
  initialUsageStats?: UsageStats;
};

function renderBookEvents(options: Partial<HookProps> = {}) {
  const callbacks = {
    onQueueState: jest.fn(),
    onChapterState: jest.fn(),
    onPageToken: jest.fn(),
    onPageDone: jest.fn(),
    onPageFailed: jest.fn(),
  };
  let props: HookProps = {
    hasProcessing: options.hasProcessing ?? true,
    initialUsageStats: options.initialUsageStats,
  };
  const hook = renderHook(
    ({ hasProcessing, initialUsageStats }: HookProps) =>
      useBookEvents({
        bookId: 'book-1',
        hasProcessing,
        initialUsageStats,
        ...callbacks,
      }),
    {
      initialProps: props,
    },
  );
  const rerenderBookEvents = (nextProps: Partial<HookProps>) => {
    props = { ...props, ...nextProps };
    hook.rerender(props);
  };
  return { ...hook, rerenderBookEvents, callbacks };
}

function usageStats(inputTokens: number, outputTokens: number): UsageStats {
  return {
    inputTokens,
    outputTokens,
    byStage: {
      translation: { inputTokens, outputTokens },
    },
  };
}

function emitUsageDelta(
  source: FakeEventSource,
  inputTokens: number,
  outputTokens: number,
) {
  source.emit({
    type: 'usage_delta',
    payload: {
      bookId: 'book-1',
      stage: 'translation',
      inputTokens,
      outputTokens,
    },
  });
}

describe('useBookEvents', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    FakeEventSource.instances = [];
    global.EventSource = FakeEventSource as unknown as typeof EventSource;
  });

  it('streams page tokens and clears temporary text on page_done', async () => {
    const { result, callbacks } = renderBookEvents();
    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    const source = FakeEventSource.instances[0];

    act(() => {
      source.emit({
        type: 'page_token',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', content: '' },
      });
      source.emit({
        type: 'page_token',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', content: '你' },
      });
      source.emit({
        type: 'page_token',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', content: '好' },
      });
    });

    expect(result.current.streamedText.p1).toBe('你好');
    expect(result.current.connectedPageIds.has('p1')).toBe(true);
    expect(callbacks.onPageToken).toHaveBeenCalledTimes(1);

    act(() => {
      source.emit({
        type: 'page_done',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', targetText: '你好' },
      });
    });

    expect(result.current.streamedText.p1).toBeUndefined();
    expect(result.current.connectedPageIds.has('p1')).toBe(false);
    expect(callbacks.onPageDone).toHaveBeenCalledWith({
      bookId: 'book-1',
      chapterId: 'ch-1',
      pageId: 'p1',
      targetText: '你好',
    });
  });

  it('clears stale streamed text when an empty page_token restarts a page', async () => {
    const { result } = renderBookEvents();
    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    const source = FakeEventSource.instances[0];

    act(() => {
      source.emit({
        type: 'page_token',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', content: '旧文本' },
      });
    });
    expect(result.current.streamedText.p1).toBe('旧文本');

    act(() => {
      source.emit({
        type: 'page_token',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', content: '' },
      });
    });

    expect(result.current.streamedText.p1).toBeUndefined();
  });

  it('clears temporary text on page_failed', async () => {
    const { result, callbacks } = renderBookEvents();
    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    const source = FakeEventSource.instances[0];

    act(() => {
      source.emit({
        type: 'page_token',
        payload: { bookId: 'book-1', chapterId: 'ch-1', pageId: 'p1', content: 'partial' },
      });
      source.emit({
        type: 'page_failed',
        payload: {
          bookId: 'book-1',
          chapterId: 'ch-1',
          pageId: 'p1',
          errorMessage: 'LLM failed',
        },
      });
    });

    expect(result.current.streamedText.p1).toBeUndefined();
    expect(result.current.connectedPageIds.has('p1')).toBe(false);
    expect(callbacks.onPageFailed).toHaveBeenCalledWith({
      bookId: 'book-1',
      chapterId: 'ch-1',
      pageId: 'p1',
      errorMessage: 'LLM failed',
    });
  });

  it('keeps live token usage when processing finishes before persisted stats refresh', async () => {
    const zeroUsage = usageStats(0, 0);
    const { result, rerenderBookEvents } = renderBookEvents({
      initialUsageStats: zeroUsage,
    });
    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    const source = FakeEventSource.instances[0];

    act(() => {
      emitUsageDelta(source, 4800, 7500);
    });

    expect(result.current.usageStats.inputTokens).toBe(4800);
    expect(result.current.usageStats.outputTokens).toBe(7500);

    act(() => {
      rerenderBookEvents({
        hasProcessing: false,
        initialUsageStats: zeroUsage,
      });
    });

    expect(result.current.usageStats.inputTokens).toBe(4800);
    expect(result.current.usageStats.outputTokens).toBe(7500);

    act(() => {
      rerenderBookEvents({
        hasProcessing: false,
        initialUsageStats: usageStats(4900, 7600),
      });
    });

    expect(result.current.usageStats.inputTokens).toBe(4900);
    expect(result.current.usageStats.outputTokens).toBe(7600);
  });
});
