"use client";

import Link from "next/link";
import { ArrowLeft, Loader2, Play, Pause, AlertCircle, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import { TranslationProgressBar } from "@/components/reader/translation-progress-bar";
import {
  ReaderSettings,
  type ReaderPrefs,
} from "@/components/reader/reader-settings";
import { DownloadPopover } from "@/components/reader/download-popover";
import { useTranslationControl } from "@/hooks/use-translation-control";
import type { GlossaryProgress } from "@/hooks/use-book-events";
import { useI18n } from "@/lib/i18n";
import { formatTokenCompact } from "@/lib/token-format";
import { type Book, type Chapter } from "@/lib/api";
import { cleanTitle } from "@/lib/utils";

interface ReaderToolbarProps {
  book: Book;
  chapters: Chapter[];
  currentChapter: Chapter | null;
  onChapterChange: (ch: Chapter) => void;
  onTranslationStarted: (
    newChapters: Chapter[],
    currentChapterId: string | null,
  ) => void;
  prefs: ReaderPrefs;
  onUpdatePrefs: (p: Partial<ReaderPrefs>) => void;
  hasTranslated: boolean;
  isLoadingPages?: boolean;
  serverPaused?: boolean;
  glossaryExtractingChapterIds?: Set<string>;
  glossaryProgress?: GlossaryProgress | null;
  isStreamingTranslation?: boolean;
  isBookComplete?: boolean;
  usageStats?: {
    inputTokens: number;
    outputTokens: number;
  } | null;
}

export function ReaderToolbar({
  book,
  chapters,
  currentChapter,
  onChapterChange,
  onTranslationStarted,
  prefs,
  onUpdatePrefs,
  hasTranslated,
  isLoadingPages = false,
  serverPaused = false,
  usageStats = null,
  glossaryExtractingChapterIds,
  glossaryProgress = null,
  isStreamingTranslation = false,
  isBookComplete = false,
}: ReaderToolbarProps) {
  const { t, locale } = useI18n();
  const control = useTranslationControl(
    book.id,
    chapters,
    currentChapter?.id ?? null,
    serverPaused,
    onTranslationStarted,
    book.status === "processing" || Boolean(glossaryProgress && glossaryProgress.completedSections < glossaryProgress.totalSections),
  );

  const phaseConfig = {
    idle: control.hasFailed
      ? ({ label: t("common.retry"), Icon: RefreshCw, variant: "outline" } as const)
      : ({ label: t("reader.toolbar.start"), Icon: Play, variant: "default" } as const),
    running: {
      label: t("reader.toolbar.pause"),
      Icon: Pause,
      variant: "ghost",
    } as const,
    paused: {
      label: t("reader.toolbar.resume"),
      Icon: Play,
      variant: "outline",
    } as const,
    done: null,
  };

  const btnCfg = phaseConfig[control.phase];
  const btnLoading =
    control.phase === "idle" ? control.startLoading : control.toggleLoading;
  const btnAction =
    control.phase === "idle" ? control.start : control.togglePause;
  const visibleError = control.error.replace(/^Error:\s*/i, "").trim();

  return (
    <div className="sticky top-[var(--header-height)] z-10 flex min-h-[52px] items-center rounded-none border-x-0 border-t-0 bg-background px-2 py-2 md:px-4">
      <div className="flex w-full min-w-0 flex-wrap items-center gap-2 md:flex-nowrap">
        <Button
          variant="ghost"
          size="icon"
          asChild
          className="h-8 w-8 shrink-0"
        >
          <Link href="/">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>

        <h2 className="min-w-0 flex-1 truncate text-[13px] font-semibold text-foreground">
          {cleanTitle(book.title)}
        </h2>
        <Separator orientation="vertical" className="hidden h-5 sm:block" />

        {chapters.length > 1 && (
          <div className="flex max-w-[280px] shrink-0 items-center gap-1.5">
            <select
              className="glass-input h-8 w-full min-w-[140px] rounded-lg border px-2 text-xs text-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              value={currentChapter?.id ?? ""}
              onChange={(e) => {
                const ch = chapters.find((c) => c.id === e.target.value);
                if (ch) onChapterChange(ch);
              }}
            >
              {chapters.map((c) => (
                <option key={c.id} value={c.id}>
                  {t("reader.toolbar.chapter", { num: c.chapterNumber })}
                  {c.title ? ` - ${c.title}` : ""}
                </option>
              ))}
            </select>
            {isLoadingPages && (
              <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground shrink-0" />
            )}
          </div>
        )}

        {currentChapter && (
          <div className="hidden min-w-[220px] shrink-0 md:flex">
            <TranslationProgressBar
              chapter={currentChapter}
              isPaused={control.isPaused}
              isStreamingTranslation={isStreamingTranslation}
              glossaryExtracting={
                (glossaryExtractingChapterIds?.has(currentChapter.id) ||
                  glossaryExtractingChapterIds?.has("__book__")) ??
                false
              }
              glossaryProgress={glossaryProgress}
            />
          </div>
        )}

        {btnCfg && (
          <div className="flex items-center gap-2 shrink-0">
            <Button
              size="sm"
              variant={btnCfg.variant}
              onClick={btnAction}
              disabled={btnLoading}
              className="h-8 gap-1.5 text-xs"
            >
              {btnLoading ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              ) : (
                <btnCfg.Icon className="h-3.5 w-3.5" />
              )}
              {btnCfg.label}
            </Button>
            {control.error && (
              <div
                className="inline-flex items-center gap-1.5 h-8 px-2 rounded-md border border-destructive/30 bg-destructive/10 text-destructive text-xs max-w-[320px]"
                title={visibleError}
              >
                <AlertCircle className="h-3.5 w-3.5" />
                <span className="truncate">
                  {t("reader.toolbar.translationFailedPrefix")}
                  {visibleError}
                </span>
              </div>
            )}
          </div>
        )}
        <Separator orientation="vertical" className="hidden h-5 sm:block" />

        {usageStats && (
          <div
            className="hidden shrink-0 items-center gap-2 text-[11px] tabular-nums text-muted-foreground/70 font-mono lg:flex"
          >
            <span>
              {t("reader.progress.inputTokens", {
                count: formatTokenCompact(usageStats.inputTokens, locale),
              })}
            </span>
            <span className="text-muted-foreground/30">/</span>
            <span>
              {t("reader.progress.outputTokens", {
                count: formatTokenCompact(usageStats.outputTokens, locale),
              })}
            </span>
          </div>
        )}
        <Separator orientation="vertical" className="hidden h-5 lg:block" />

        <DownloadPopover
          bookId={book.id}
          status={isBookComplete ? "completed" : book.status}
          hasTranslated={hasTranslated}
        />
        <ReaderSettings prefs={prefs} onUpdate={onUpdatePrefs} />
      </div>
    </div>
  );
}
