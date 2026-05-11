"use client";

import { use, useRef, useMemo, useState, useEffect, useCallback } from "react";
import Link from "next/link";
import {
  BookOpen,
  AlertCircle,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import { AppShell } from "@/components/layout/app-shell";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ReaderToolbar } from "@/components/reader/reader-toolbar";
import { PageRow } from "@/components/reader/page-row";
import { TtftBadge } from "@/components/reader/ttft-badge";
import {
  useReaderPrefs,
  fontSizeClass,
  lineHeightClass,
} from "@/components/reader/reader-settings";
import { useBook } from "@/hooks/use-book";
import { useBookEvents } from "@/hooks/use-book-events";
import { useChapterPages } from "@/hooks/use-chapter-pages";
import { useSplitPane } from "@/hooks/use-split-pane";
import { usePageObserver } from "@/hooks/use-page-observer";
import { useReaderVirtualWindow } from "@/hooks/use-reader-virtual-window";
import { useI18n } from "@/lib/i18n";
import { fetchPagesByChapter } from "@/lib/api";
import { cn } from "@/lib/utils";


const SKELETON_WIDTHS = [
  "75%",
  "60%",
  "90%",
  "45%",
  "80%",
  "55%",
  "70%",
  "65%",
  "85%",
  "50%",
];

function useIsMobileReader() {
  const [isMobile, setIsMobile] = useState(false);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 767px)");
    const sync = () => setIsMobile(media.matches);
    sync();
    media.addEventListener("change", sync);
    return () => media.removeEventListener("change", sync);
  }, []);

  return isMobile;
}

function ReaderSkeleton() {
  return (
    <AppShell>
      <div className="sticky top-[52px] z-10 border-b border-border bg-background/95 px-6 py-3">
        <div className="flex items-center gap-3">
          <Skeleton className="h-8 w-8 rounded-md shrink-0" />
          <Skeleton className="h-4 w-48" />
          <div className="flex-1" />
          <Skeleton className="h-6 w-32 rounded-full" />
          <Skeleton className="h-8 w-20 rounded-md" />
          <Skeleton className="h-8 w-8 rounded-md" />
          <Skeleton className="h-8 w-8 rounded-md" />
        </div>
      </div>
      <div className="flex h-[calc(100vh-52px-57px)]">
        <div className="w-1/2 px-8 py-10 space-y-4">
          {SKELETON_WIDTHS.map((w, i) => (
            <Skeleton key={i} className="h-4" style={{ width: w }} />
          ))}
        </div>
        <div className="w-px bg-border/30 shrink-0" />
        <div className="flex-1 px-8 py-10 space-y-4">
          {SKELETON_WIDTHS.map((w, i) => (
            <Skeleton key={i} className="h-4" style={{ width: w }} />
          ))}
        </div>
      </div>
    </AppShell>
  );
}

export default function ReaderPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { t } = useI18n();
  const { id: bookId } = use(params);
  const pageRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const currentChapterIdRef = useRef<string | null>(null);
  const refreshingChapterIdsRef = useRef<Set<string>>(new Set());

  const {
    book,
    chapters,
    setChapters,
    currentChapter,
    setCurrentChapter,
    loading,
    error,
  } = useBook(bookId);
  const {
    pages,
    setPages,
    visiblePages,
    isLoading: isLoadingPages,
  } = useChapterPages(bookId, currentChapter);
  const splitPane = useSplitPane();
  const isMobileReader = useIsMobileReader();
  const [serverPaused, setServerPaused] = useState(false);
  const hasProcessing =
    book?.status === "processing" || chapters.some((c) => c.status === "processing");
  const isTranslationOnly = splitPane.isCollapsed || isMobileReader;
  const persistedUsageStats = useMemo(
    () => ({
      inputTokens: Math.max(0, Math.round(book?.usageInputTokens ?? 0)),
      outputTokens: Math.max(0, Math.round(book?.usageOutputTokens ?? 0)),
      byStage: book?.usageByStage ?? {},
    }),
    [book?.usageByStage, book?.usageInputTokens, book?.usageOutputTokens],
  );

  useEffect(() => {
    currentChapterIdRef.current = currentChapter?.id ?? null;
  }, [currentChapter?.id]);

  const refreshCurrentChapterPages = useCallback(
    async (chapterId: string) => {
      if (currentChapterIdRef.current !== chapterId) return;
      if (refreshingChapterIdsRef.current.has(chapterId)) return;
      refreshingChapterIdsRef.current.add(chapterId);
      try {
        const nextPages = await fetchPagesByChapter(chapterId);
        if (currentChapterIdRef.current === chapterId) {
          setPages(nextPages);
        }
      } finally {
        refreshingChapterIdsRef.current.delete(chapterId);
      }
    },
    [setPages],
  );
  const stream = useBookEvents({
    bookId,
    hasProcessing,
    initialUsageStats: persistedUsageStats,
    onQueueState: setServerPaused,
    onChapterState: useCallback(
      (payload) => {
        if (payload.bookId !== bookId) return;
        setChapters((prev) =>
          prev.map((chapter) =>
            chapter.id === payload.chapterId
              ? {
                  ...chapter,
                  status: payload.status,
                  translationProgress: payload.translationProgress,
                  tokensPerSecond: payload.tokensPerSecond ?? null,
                  translationStartedAt: payload.translationStartedAt ?? null,
                }
              : chapter,
          ),
        );
        setCurrentChapter((prev) =>
          prev && prev.id === payload.chapterId
            ? {
                ...prev,
                status: payload.status,
                translationProgress: payload.translationProgress,
                tokensPerSecond: payload.tokensPerSecond ?? null,
                translationStartedAt: payload.translationStartedAt ?? null,
              }
            : prev,
        );
        void refreshCurrentChapterPages(payload.chapterId);
      },
      [bookId, refreshCurrentChapterPages, setChapters, setCurrentChapter],
    ),
    onPageToken: useCallback(
      (payload) => {
        if (payload.bookId !== bookId) return;
        setPages((prev) =>
          prev.map((page) =>
            page.id === payload.pageId
              ? { ...page, translationStatus: "processing" }
              : page,
          ),
        );
      },
      [bookId, setPages],
    ),
    onPageDone: useCallback(
      (payload) => {
        if (payload.bookId !== bookId) return;
        setPages((prev) =>
          prev.map((page) =>
            page.id === payload.pageId
              ? {
                  ...page,
                  translationStatus: "completed",
                  targetText: payload.targetText,
                  errorMessage: null,
                }
              : page,
          ),
        );
      },
      [bookId, setPages],
    ),
    onPageFailed: useCallback(
      (payload) => {
        if (payload.bookId !== bookId) return;
        setPages((prev) =>
          prev.map((page) =>
            page.id === payload.pageId
              ? {
                  ...page,
                  translationStatus: "failed",
                  errorMessage: payload.errorMessage,
                }
              : page,
          ),
        );
      },
      [bookId, setPages],
    ),
  });
  const { activePageId } = usePageObserver(
    visiblePages,
    pageRefs,
  );
  const { prefs, updatePrefs } = useReaderPrefs();

  const fontSize = fontSizeClass(prefs.fontSize);
  const lineHeight = lineHeightClass(prefs.lineHeight);

  const processingIds = useMemo(
    () =>
      new Set(
        visiblePages
          .filter((p) => p.translationStatus === "processing")
          .map((p) => p.id),
      ),
    [visiblePages],
  );

  const virtualWindow = useReaderVirtualWindow({
    visiblePages,
    processingIds,
    currentChapterId: currentChapter?.id,
    activePageId,
    isTranslationOnly,
    pageRefs,
    scrollRef,
  });
  const { scrollToPageId } = virtualWindow;

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      e.preventDefault();
      const idx = pages.findIndex((p) => p.id === activePageId);
      if (idx === -1) return;
      const target = e.key === "ArrowRight" ? pages[idx + 1] : pages[idx - 1];
      if (target) scrollToPageId(target.id);
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [pages, activePageId, scrollToPageId]);

  const activePageNum = useMemo(
    () =>
      activePageId
        ? (pages.find((p) => p.id === activePageId)?.pageNumber ?? 1)
        : (pages[0]?.pageNumber ?? 1),
    [activePageId, pages],
  );
  const currentChapterPageIds = useMemo(
    () => new Set(pages.map((page) => page.id)),
    [pages],
  );
  const isStreamingCurrentChapter = useMemo(
    () =>
      Array.from(stream.connectedPageIds).some((pageId) =>
        currentChapterPageIds.has(pageId),
      ),
    [currentChapterPageIds, stream.connectedPageIds],
  );

  if (loading) return <ReaderSkeleton />;

  if (error || !book) {
    return (
      <AppShell>
        <div className="flex flex-col items-center justify-center h-[calc(100vh-52px)] gap-4">
          <AlertCircle className="h-10 w-10 text-destructive" />
          <p className="text-sm text-muted-foreground">
            {error ?? t("reader.bookNotFound")}
          </p>
          <Button asChild variant="outline">
            <Link href="/">{t("reader.back")}</Link>
          </Button>
        </div>
      </AppShell>
    );
  }

  const showPageSkeleton = isLoadingPages && pages.length === 0;
  const showEmpty = !isLoadingPages && visiblePages.length === 0;
  const allChaptersCompleted =
    chapters.length > 0 && chapters.every((chapter) => chapter.status === "completed");

  return (
    <AppShell>
      <div className="bg-background">
      <ReaderToolbar
        book={book}
        chapters={chapters}
        currentChapter={currentChapter}
        onChapterChange={setCurrentChapter}
        onTranslationStarted={(chs, currentChapterId) => {
          setChapters(chs);
          setCurrentChapter(
            chs.find((c) => c.id === currentChapterId) ?? chs[0],
          );
        }}
        prefs={prefs}
        onUpdatePrefs={updatePrefs}
        hasTranslated={pages.some((p) => p.translationStatus === "completed")}
        isLoadingPages={isLoadingPages}
        serverPaused={serverPaused}
        usageStats={stream.usageStats}
        glossaryExtractingChapterIds={stream.glossaryExtractingChapterIds}
        glossaryProgress={stream.glossaryProgress}
        isStreamingTranslation={isStreamingCurrentChapter}
        isBookComplete={allChaptersCompleted}
      />

      {}
      {visiblePages.length > 0 && (
        <div
          className="fixed z-30 hidden -translate-x-1/2 -translate-y-1/2 md:block"
          style={{
            top: "50vh",
            left: splitPane.collapseLeft,
            transition: "left 0.2s ease",
          }}
        >
          <button
            className={cn(
              "flex items-center justify-center w-6 h-10 rounded-full",
              "bg-background border border-border shadow-md",
              "transition-opacity duration-100",
              "hover:bg-secondary hover:border-primary/50 hover:opacity-100",
              splitPane.isCollapsed
                ? "opacity-75"
                : splitPane.isDividerHovered
                  ? "opacity-100"
                  : "opacity-40",
            )}
            onMouseEnter={() => splitPane.setIsDividerHovered(true)}
            onMouseLeave={() => splitPane.setIsDividerHovered(false)}
            onClick={splitPane.toggleCollapse}
            title={
              splitPane.isCollapsed
                ? t("reader.toolbar.showSource")
                : t("reader.toolbar.hideSource")
            }
          >
            {splitPane.isCollapsed ? (
              <ChevronRight className="h-3 w-3 text-muted-foreground" />
            ) : (
              <ChevronLeft className="h-3 w-3 text-muted-foreground" />
            )}
          </button>
        </div>
      )}

      {}
      {pages.length > 0 && (
        <div className="fixed bottom-5 right-6 z-20 pointer-events-none select-none">
          <span className="rounded-full border border-border bg-background px-2.5 py-1 text-[11px] tabular-nums text-muted-foreground font-mono shadow-sm">
            {activePageNum} / {pages.length}
          </span>
        </div>
      )}

      {}
      {showPageSkeleton ? (
        <div className="flex h-[calc(100vh-52px-57px)]">
          <div className="w-1/2 px-8 py-10 space-y-4">
            {SKELETON_WIDTHS.map((w, i) => (
              <Skeleton key={i} className="h-4" style={{ width: w }} />
            ))}
          </div>
          <div className="w-px bg-border/30 shrink-0" />
          <div className="flex-1 px-8 py-10 space-y-4">
            {SKELETON_WIDTHS.map((w, i) => (
              <Skeleton key={i} className="h-4" style={{ width: w }} />
            ))}
          </div>
        </div>
      ) : showEmpty ? (
        <div className="flex flex-col items-center justify-center h-[calc(100vh-52px-57px)] gap-3">
          <BookOpen className="h-12 w-12 text-muted-foreground opacity-40" />
          <p className="text-sm text-muted-foreground">{t("reader.noPages")}</p>
        </div>
      ) : (
        <div
          ref={splitPane.containerRef}
          className="h-[calc(100vh-var(--header-height)-57px)] overflow-hidden flex flex-col"
        >
          <div className="flex-1 overflow-y-auto" ref={scrollRef}>
            {virtualWindow.topSpacerHeight > 0 && (
              <div style={{ height: virtualWindow.topSpacerHeight }} />
            )}
            {virtualWindow.visibleWindowPages.map((page) => {
              const index = virtualWindow.indexById.get(page.id) ?? 0;
              const prevHasContent = visiblePages
                .slice(0, index)
                .some(
                  (p) =>
                    !(p.ocrStatus === "completed" && !p.sourceText?.trim()),
                );
              return (
                <PageRow
                  key={page.id}
                  page={page}
                  showDivider={prevHasContent}
                  splitRatio={splitPane.splitRatio}
                  isCollapsed={splitPane.isCollapsed}
                  isDividerHovered={splitPane.isDividerHovered}
                  onDividerMouseDown={splitPane.handleDividerMouseDown}
                  onDividerHoverChange={splitPane.setIsDividerHovered}
                  fontSize={fontSize}
                  lineHeight={lineHeight}
                  streamedText={stream.streamedText[page.id]}
                  isConnected={stream.connectedPageIds.has(page.id)}
                  isReviewing={stream.reviewingPageIds.has(page.id)}
                  isPolishing={stream.polishingPageIds.has(page.id)}
                  isTranslationOnly={isTranslationOnly}
                  onRef={(el) => virtualWindow.registerPageElement(page.id, el)}
                />
              );
            })}
            {virtualWindow.bottomSpacerHeight > 0 && (
              <div style={{ height: virtualWindow.bottomSpacerHeight }} />
            )}
            <div className="h-24" />
          </div>
        </div>
      )}

      <TtftBadge ttftMs={stream.ttftMs} />
      </div>
    </AppShell>
  );
}
