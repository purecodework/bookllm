"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MutableRefObject,
} from "react";

const PAGE_BATCH = 10;
const PAGE_OVERSCAN = 4;
const ESTIMATED_PAGE_HEIGHT = 700;

interface ReaderVirtualPage {
  id: string;
}

interface UseReaderVirtualWindowOptions<TPage extends ReaderVirtualPage> {
  visiblePages: TPage[];
  processingIds: Set<string>;
  currentChapterId?: string | null;
  activePageId?: string | null;
  isTranslationOnly: boolean;
  pageRefs: MutableRefObject<Map<string, HTMLDivElement>>;
  scrollRef: MutableRefObject<HTMLDivElement | null>;
}

export function useReaderVirtualWindow<TPage extends ReaderVirtualPage>({
  visiblePages,
  processingIds,
  currentChapterId,
  activePageId,
  isTranslationOnly,
  pageRefs,
  scrollRef,
}: UseReaderVirtualWindowOptions<TPage>) {
  const resizeObserversRef = useRef<Map<string, ResizeObserver>>(new Map());
  const pageHeightsRef = useRef<Map<string, number>>(new Map());
  const layoutKeyRef = useRef("");
  const pendingAnchorIdRef = useRef<string | null>(null);
  const [windowStart, setWindowStart] = useState(0);
  const [windowEnd, setWindowEnd] = useState(PAGE_BATCH + PAGE_OVERSCAN);

  useEffect(() => {
    setWindowStart(0);
    setWindowEnd(PAGE_BATCH + PAGE_OVERSCAN);
  }, [currentChapterId]);

  const visibleWindowPages = useMemo(() => {
    const slice = visiblePages.slice(windowStart, windowEnd + 1);
    const map = new Map(slice.map((page) => [page.id, page]));
    for (const page of visiblePages) {
      if (processingIds.has(page.id)) map.set(page.id, page);
    }
    return visiblePages.filter((page) => map.has(page.id));
  }, [visiblePages, windowStart, windowEnd, processingIds]);

  const indexById = useMemo(
    () => new Map(visiblePages.map((page, index) => [page.id, index])),
    [visiblePages],
  );

  const topSpacerHeight = useMemo(() => {
    let total = 0;
    for (let index = 0; index < windowStart; index += 1) {
      const page = visiblePages[index];
      if (!page || processingIds.has(page.id)) continue;
      total += pageHeightsRef.current.get(page.id) ?? ESTIMATED_PAGE_HEIGHT;
    }
    return total;
  }, [visiblePages, windowStart, processingIds]);

  const bottomSpacerHeight = useMemo(() => {
    let total = 0;
    for (let index = windowEnd + 1; index < visiblePages.length; index += 1) {
      const page = visiblePages[index];
      if (!page || processingIds.has(page.id)) continue;
      total += pageHeightsRef.current.get(page.id) ?? ESTIMATED_PAGE_HEIGHT;
    }
    return total;
  }, [visiblePages, windowEnd, processingIds]);

  const findScrollAnchorId = useCallback(() => {
    const scroller = scrollRef.current;
    if (!scroller) return null;
    if (typeof scroller.getBoundingClientRect !== "function") return null;
    const scrollerTop = scroller.getBoundingClientRect().top;
    let best: { id: string; distance: number } | null = null;
    for (const page of visiblePages) {
      const element = pageRefs.current.get(page.id);
      if (!element) continue;
      if (typeof element.getBoundingClientRect !== "function") continue;
      const distance = Math.abs(element.getBoundingClientRect().top - scrollerTop);
      if (!best || distance < best.distance) {
        best = { id: page.id, distance };
      }
    }
    return best?.id ?? null;
  }, [pageRefs, scrollRef, visiblePages]);

  const recalcWindow = useCallback(() => {
    const scroller = scrollRef.current;
    if (!scroller || visiblePages.length <= PAGE_BATCH + PAGE_OVERSCAN) return;
    if (pendingAnchorIdRef.current) return;

    const viewportTop = scroller.scrollTop;
    const viewportBottom = viewportTop + scroller.clientHeight;

    let cursor = 0;
    let first = 0;
    let last = visiblePages.length - 1;

    for (let index = 0; index < visiblePages.length; index += 1) {
      const page = visiblePages[index];
      const height =
        pageHeightsRef.current.get(page.id) ?? ESTIMATED_PAGE_HEIGHT;
      const next = cursor + height;
      if (next >= viewportTop) {
        first = index;
        break;
      }
      cursor = next;
    }

    cursor = 0;
    for (let index = 0; index < visiblePages.length; index += 1) {
      const page = visiblePages[index];
      const height =
        pageHeightsRef.current.get(page.id) ?? ESTIMATED_PAGE_HEIGHT;
      cursor += height;
      if (cursor >= viewportBottom) {
        last = index;
        break;
      }
    }

    const nextStart = Math.max(0, first - PAGE_OVERSCAN);
    const nextEnd = Math.min(visiblePages.length - 1, last + PAGE_OVERSCAN);
    setWindowStart((prev) =>
      Math.abs(prev - nextStart) >= 2 ? nextStart : prev,
    );
    setWindowEnd((prev) => (Math.abs(prev - nextEnd) >= 2 ? nextEnd : prev));
  }, [scrollRef, visiblePages]);

  useEffect(() => {
    const layoutKey = `${currentChapterId ?? "none"}:${isTranslationOnly}`;
    if (layoutKeyRef.current === layoutKey) return;
    if (visiblePages.length === 0) return;
    layoutKeyRef.current = layoutKey;

    const anchorId = activePageId ?? findScrollAnchorId() ?? visiblePages[windowStart]?.id;
    const anchorIndex = anchorId
      ? visiblePages.findIndex((page) => page.id === anchorId)
      : -1;
    const normalizedAnchorIndex = anchorIndex >= 0 ? anchorIndex : 0;
    const nextStart = Math.max(0, normalizedAnchorIndex - PAGE_OVERSCAN);
    const nextEnd = Math.min(
      visiblePages.length - 1,
      Math.max(
        nextStart + PAGE_BATCH + PAGE_OVERSCAN,
        normalizedAnchorIndex + PAGE_OVERSCAN,
      ),
    );

    pendingAnchorIdRef.current = anchorId ?? visiblePages[normalizedAnchorIndex]?.id ?? null;
    pageHeightsRef.current.clear();
    setWindowStart(nextStart);
    setWindowEnd(nextEnd);

    requestAnimationFrame(() => {
      const pendingAnchorId = pendingAnchorIdRef.current;
      if (pendingAnchorId) {
        pageRefs.current.get(pendingAnchorId)?.scrollIntoView({ block: "start" });
      }
      pendingAnchorIdRef.current = null;
      recalcWindow();
    });
  }, [
    activePageId,
    currentChapterId,
    findScrollAnchorId,
    isTranslationOnly,
    pageRefs,
    recalcWindow,
    visiblePages,
    windowStart,
  ]);

  useEffect(() => {
    const scroller = scrollRef.current;
    if (!scroller) return;
    const onScroll = () => recalcWindow();
    scroller.addEventListener("scroll", onScroll, { passive: true });
    recalcWindow();
    return () => scroller.removeEventListener("scroll", onScroll);
  }, [recalcWindow, scrollRef]);

  useEffect(() => {
    const observers = resizeObserversRef.current;
    return () => {
      for (const observer of observers.values()) {
        observer.disconnect();
      }
      observers.clear();
    };
  }, []);

  const registerPageElement = useCallback(
    (pageId: string, element: HTMLDivElement | null) => {
      const old = pageRefs.current.get(pageId);
      if (old && old !== element) {
        const observer = resizeObserversRef.current.get(pageId);
        observer?.disconnect();
        resizeObserversRef.current.delete(pageId);
      }

      if (element) {
        pageRefs.current.set(pageId, element);
        const measure = () => {
          const height = element.getBoundingClientRect().height;
          if (height > 0) {
            pageHeightsRef.current.set(pageId, height);
          }
        };
        measure();
        if (typeof ResizeObserver !== "undefined") {
          let observer = resizeObserversRef.current.get(pageId);
          if (!observer) {
            observer = new ResizeObserver(() => {
              measure();
              recalcWindow();
            });
            resizeObserversRef.current.set(pageId, observer);
          }
          observer.observe(element);
        }
      } else {
        pageRefs.current.delete(pageId);
        const observer = resizeObserversRef.current.get(pageId);
        observer?.disconnect();
        resizeObserversRef.current.delete(pageId);
      }
      recalcWindow();
    },
    [pageRefs, recalcWindow],
  );

  const scrollToPageId = useCallback(
    (pageId: string) => {
      const pageIndex = visiblePages.findIndex((page) => page.id === pageId);
      if (pageIndex < 0) return;
      setWindowStart((prev) => Math.min(prev, Math.max(0, pageIndex - PAGE_OVERSCAN)));
      setWindowEnd((prev) => Math.max(prev, pageIndex + PAGE_OVERSCAN));
      requestAnimationFrame(() => {
        const element = pageRefs.current.get(pageId);
        if (element) {
          element.scrollIntoView({ behavior: "smooth", block: "start" });
          return;
        }

        let top = 0;
        for (let index = 0; index < pageIndex; index += 1) {
          top +=
            pageHeightsRef.current.get(visiblePages[index]?.id ?? "") ??
            ESTIMATED_PAGE_HEIGHT;
        }
        scrollRef.current?.scrollTo({ top, behavior: "smooth" });
      });
    },
    [pageRefs, scrollRef, visiblePages],
  );

  return {
    visibleWindowPages,
    indexById,
    topSpacerHeight,
    bottomSpacerHeight,
    recalcWindow,
    registerPageElement,
    scrollToPageId,
  };
}
