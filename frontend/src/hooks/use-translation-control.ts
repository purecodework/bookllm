"use client";

import { useState, useEffect, useCallback } from "react";
import { pauseTranslation, resumeTranslation, type Chapter } from "@/lib/api";
import { useStartTranslation } from "@/hooks/use-start-translation";

export type TranslationPhase = "idle" | "running" | "paused" | "done";

export function useTranslationControl(
  bookId: string,
  chapters: Chapter[],
  currentChapterId: string | null,
  serverPaused: boolean,
  onTranslationStarted: (
    chs: Chapter[],
    currentChapterId: string | null,
  ) => void,
  hasExternalProcessing = false,
) {
  const [isPaused, setIsPaused] = useState(false);
  const [toggling, setToggling] = useState(false);
  const { translating, error, trigger } = useStartTranslation(bookId);

  const isProcessing = hasExternalProcessing || chapters.some((c) => c.status === "processing");
  const isAllDone =
    chapters.length > 0 && chapters.every((c) => c.status === "completed");
  const hasFailed =
    !isProcessing && chapters.some((c) => c.status === "failed");

  const phase: TranslationPhase = isAllDone
    ? "done"
    : isProcessing && isPaused
      ? "paused"
      : isProcessing
        ? "running"
        : "idle";

  useEffect(() => {
    setIsPaused(serverPaused);
  }, [serverPaused, isProcessing, currentChapterId]);

  const start = useCallback(async () => {
    const chs = await trigger();
    if (chs) {
      setIsPaused(false);
      onTranslationStarted(chs, currentChapterId);
    }
  }, [trigger, onTranslationStarted, currentChapterId]);

  const togglePause = useCallback(async () => {
    if (toggling) return;
    setToggling(true);
    try {
      const chapterId =
        chapters.find((c) => c.status === "processing")?.id ?? chapters[0]?.id;
      if (!chapterId) return;
      if (isPaused) {
        await resumeTranslation(chapterId);
        setIsPaused(false);
      } else {
        await pauseTranslation(chapterId);
        setIsPaused(true);
      }
    } finally {
      setToggling(false);
    }
  }, [toggling, isPaused, chapters]);

  return {
    phase,
    isPaused,
    hasFailed,
    start,
    togglePause,
    startLoading: translating,
    toggleLoading: toggling,
    error,
  };
}
