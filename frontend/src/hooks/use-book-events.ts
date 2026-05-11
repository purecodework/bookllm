"use client";

import { useEffect, useRef, useState } from "react";
import { parseSseJson } from "@/lib/sse";
import { getApiBase } from "@/lib/api-base";

type QueueStateEvent = {
  type: "queue_state";
  payload: { bookId: string; isPaused: boolean };
};

type ChapterStateEvent = {
  type: "chapter_state";
  payload: {
    bookId: string;
    chapterId: string;
    status: string;
    translationProgress: number;
    tokensPerSecond?: number | null;
    translationStartedAt?: string | null;
  };
};

type PageTokenEvent = {
  type: "page_token";
  payload: {
    bookId: string;
    chapterId: string;
    pageId: string;
    content: string;
  };
};

type PageDoneEvent = {
  type: "page_done";
  payload: {
    bookId: string;
    chapterId: string;
    pageId: string;
    targetText: string;
  };
};

type PageFailedEvent = {
  type: "page_failed";
  payload: {
    bookId: string;
    chapterId: string;
    pageId: string;
    errorMessage: string;
  };
};

type PageReviewingEvent = {
  type: "page_reviewing";
  payload: {
    bookId: string;
    chapterId: string;
    pageId: string;
  };
};

type PageReviewedEvent = {
  type: "page_reviewed";
  payload: {
    bookId: string;
    chapterId: string;
    pageId: string;
    targetText: string;
  };
};

type PagePolishingEvent = {
  type: "page_polishing";
  payload: {
    bookId: string;
    chapterId: string;
    pageId: string;
  };
};

type GlossaryExtractingEvent = {
  type: "glossary_extracting";
  payload: {
    bookId: string;
    chapterId: string;
    extracting: boolean;
  };
};

export type GlossaryProgress = {
  bookId: string;
  completedSections: number;
  totalSections: number;
  currentSectionId?: string;
  elapsedMs: number;
  estimatedRemainingMs?: number;
};

type GlossaryProgressEvent = {
  type: "glossary_progress";
  payload: GlossaryProgress;
};

export type UsageStats = {
  inputTokens: number;
  outputTokens: number;
  byStage: Record<string, { inputTokens: number; outputTokens: number }>;
};

const EMPTY_USAGE_STATS: UsageStats = {
  inputTokens: 0,
  outputTokens: 0,
  byStage: {},
};

function normalizeUsageStats(stats?: UsageStats): UsageStats {
  return stats ?? EMPTY_USAGE_STATS;
}

function shouldUseIncomingUsageStats(current: UsageStats, incoming: UsageStats) {
  return (
    incoming.inputTokens >= current.inputTokens &&
    incoming.outputTokens >= current.outputTokens
  );
}

type UsageDeltaEvent = {
  type: "usage_delta";
  payload: {
    bookId: string;
    stage: "glossary" | "translation" | "review" | "polish";
    pageId?: string;
    sectionId?: string;
    inputTokens?: number;
    outputTokens?: number;
  };
};

type PipelinePhaseEvent = {
  type: "pipeline_phase";
  payload: {
    bookId: string;
    phase: "glossary" | "translation" | "review" | "polish" | "completed";
    pageId?: string;
    label?: string;
  };
};

type BookEvent =
  | QueueStateEvent
  | ChapterStateEvent
  | PageTokenEvent
  | PageDoneEvent
  | PageFailedEvent
  | PageReviewingEvent
  | PageReviewedEvent
  | PagePolishingEvent
  | GlossaryExtractingEvent
  | GlossaryProgressEvent
  | UsageDeltaEvent
  | PipelinePhaseEvent;

interface BookEventsOptions {
  bookId?: string;
  hasProcessing: boolean;
  initialUsageStats?: UsageStats;
  onQueueState: (isPaused: boolean) => void;
  onChapterState: (payload: ChapterStateEvent["payload"]) => void;
  onPageToken: (payload: PageTokenEvent["payload"]) => void;
  onPageDone: (payload: PageDoneEvent["payload"]) => void;
  onPageFailed: (payload: PageFailedEvent["payload"]) => void;
}

export function useBookEvents({
  bookId,
  hasProcessing,
  initialUsageStats,
  onQueueState,
  onChapterState,
  onPageToken,
  onPageDone,
  onPageFailed,
}: BookEventsOptions) {
  const [streamedText, setStreamedText] = useState<Record<string, string>>({});

  const [glossaryExtractingChapterIds, setGlossaryExtractingChapterIds] = useState<Set<string>>(
    () => new Set(),
  );

  const [reviewingPageIds, setReviewingPageIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [polishingPageIds, setPolishingPageIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [glossaryProgress, setGlossaryProgress] =
    useState<GlossaryProgress | null>(null);
  const [usageStats, setUsageStats] = useState<UsageStats>(
    () => normalizeUsageStats(initialUsageStats),
  );
  const [ttftMs, setTtftMs] = useState<number | null>(null);
  const [connectedPageIds, setConnectedPageIds] = useState<Set<string>>(
    () => new Set(),
  );
  const connectedPagesRef = useRef<Set<string>>(new Set());
  const startTimeRef = useRef<Record<string, number>>({});
  const firstTokenPageIds = useRef<Set<string>>(new Set());
  const ttftFiredRef = useRef(false);
  const hadProcessingRef = useRef(false);

  useEffect(() => {
    if (hasProcessing && !hadProcessingRef.current) {
      ttftFiredRef.current = false;
      firstTokenPageIds.current.clear();
      startTimeRef.current = {};
      setTtftMs(null);
      setGlossaryProgress(null);
      setUsageStats(normalizeUsageStats(initialUsageStats));
    }
    hadProcessingRef.current = hasProcessing;
  }, [hasProcessing, initialUsageStats]);

  useEffect(() => {
    if (hasProcessing) return;
    const incoming = normalizeUsageStats(initialUsageStats);
    setUsageStats((current) =>
      shouldUseIncomingUsageStats(current, incoming) ? incoming : current,
    );
  }, [hasProcessing, initialUsageStats]);

  useEffect(() => {
    if (!bookId) return;
    const apiBase = getApiBase();
    const es = new EventSource(`${apiBase}/events/book/${bookId}`);

    const fireTtftOnce = (pageId: string) => {
      if (ttftFiredRef.current) return;
      ttftFiredRef.current = true;
      const ms = Date.now() - (startTimeRef.current[pageId] ?? Date.now());
      if (ms > 0) setTtftMs(ms);
    };

    es.onmessage = (e: MessageEvent<string>) => {
      const event = parseSseJson<BookEvent>(e.data);
      if (!event) return;

      if (event.type === "queue_state") {
        onQueueState(event.payload.isPaused);
        return;
      }
      if (event.type === "chapter_state") {
        onChapterState(event.payload);
        return;
      }
      if (event.type === "page_token") {
        const { pageId, content } = event.payload;
        const wasConnected = connectedPagesRef.current.has(pageId);
        if (!wasConnected) {
          connectedPagesRef.current.add(pageId);
          setConnectedPageIds(new Set(connectedPagesRef.current));
          onPageToken(event.payload);
        }
        if (!startTimeRef.current[pageId]) {
          startTimeRef.current[pageId] = Date.now();
        }
        if (!firstTokenPageIds.current.has(pageId) && content) {
          firstTokenPageIds.current.add(pageId);
          fireTtftOnce(pageId);
        }
        if (content) {
          setStreamedText((prev) => ({
            ...prev,
            [pageId]: (prev[pageId] ?? "") + content,
          }));
        } else {
          setStreamedText((prev) => {
            if (!(pageId in prev)) return prev;
            const next = { ...prev };
            delete next[pageId];
            return next;
          });
        }
        return;
      }
      if (event.type === "glossary_extracting") {
        setGlossaryExtractingChapterIds((prev) => {
          const next = new Set(prev);
          if (event.payload.extracting) {
            next.add(event.payload.chapterId);
          } else {
            next.delete(event.payload.chapterId);
          }
          return next;
        });
        return;
      }
      if (event.type === "glossary_progress") {
        setGlossaryProgress(event.payload);
        return;
      }
      if (event.type === "usage_delta") {
        const input = Math.max(0, Math.round(event.payload.inputTokens ?? 0));
        const output = Math.max(0, Math.round(event.payload.outputTokens ?? 0));
        setUsageStats((prev) => {
          const current = prev.byStage[event.payload.stage] ?? {
            inputTokens: 0,
            outputTokens: 0,
          };
          const nextStage = {
            inputTokens: current.inputTokens + input,
            outputTokens: current.outputTokens + output,
          };
          return {
            inputTokens: prev.inputTokens + input,
            outputTokens: prev.outputTokens + output,
            byStage: {
              ...prev.byStage,
              [event.payload.stage]: nextStage,
            },
          };
        });
        return;
      }
      if (event.type === "pipeline_phase") {
        return;
      }
      if (event.type === "page_reviewing") {
        setReviewingPageIds((prev) => {
          const next = new Set(prev);
          next.add(event.payload.pageId);
          return next;
        });
        return;
      }
      if (event.type === "page_reviewed") {
        setReviewingPageIds((prev) => {
          if (!prev.has(event.payload.pageId)) return prev;
          const next = new Set(prev);
          next.delete(event.payload.pageId);
          return next;
        });
        setStreamedText((prev) => ({
          ...prev,
          [event.payload.pageId]: event.payload.targetText,
        }));
        onPageDone(event.payload);
        return;
      }
      if (event.type === "page_polishing") {
        setPolishingPageIds((prev) => {
          const next = new Set(prev);
          next.add(event.payload.pageId);
          return next;
        });
        return;
      }
      if (event.type === "page_done") {
        connectedPagesRef.current.delete(event.payload.pageId);
        setConnectedPageIds(new Set(connectedPagesRef.current));
        setReviewingPageIds((prev) => {
          if (!prev.has(event.payload.pageId)) return prev;
          const next = new Set(prev);
          next.delete(event.payload.pageId);
          return next;
        });
        setPolishingPageIds((prev) => {
          if (!prev.has(event.payload.pageId)) return prev;
          const next = new Set(prev);
          next.delete(event.payload.pageId);
          return next;
        });
        setStreamedText((prev) => {
          if (!(event.payload.pageId in prev)) return prev;
          const next = { ...prev };
          delete next[event.payload.pageId];
          return next;
        });
        onPageDone(event.payload);
        return;
      }
      if (event.type === "page_failed") {
        connectedPagesRef.current.delete(event.payload.pageId);
        setConnectedPageIds(new Set(connectedPagesRef.current));
        setReviewingPageIds((prev) => {
          if (!prev.has(event.payload.pageId)) return prev;
          const next = new Set(prev);
          next.delete(event.payload.pageId);
          return next;
        });
        setPolishingPageIds((prev) => {
          if (!prev.has(event.payload.pageId)) return prev;
          const next = new Set(prev);
          next.delete(event.payload.pageId);
          return next;
        });
        setStreamedText((prev) => {
          if (!(event.payload.pageId in prev)) return prev;
          const next = { ...prev };
          delete next[event.payload.pageId];
          return next;
        });
        onPageFailed(event.payload);
      }
    };

    const connectedPages = connectedPagesRef.current;
    return () => {
      es.close();
      connectedPages.clear();
      setConnectedPageIds(new Set());
      setReviewingPageIds(new Set());
      setPolishingPageIds(new Set());
    };
  }, [
    bookId,
    onChapterState,
    onPageDone,
    onPageFailed,
    onPageToken,
    onQueueState,
  ]);

  useEffect(() => {
    if (ttftMs === null) return;
    const t = setTimeout(() => setTtftMs(null), 5000);
    return () => clearTimeout(t);
  }, [ttftMs]);

  return {
    streamedText,
    ttftMs,
    connectedPageIds,
    reviewingPageIds,
    polishingPageIds,
    glossaryExtractingChapterIds,
    glossaryProgress,
    usageStats,
  };
}
