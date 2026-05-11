"use client";

import { useState, useEffect, useMemo } from "react";
import { fetchPagesByChapter, type Chapter, type Page } from "@/lib/api";

export function useChapterPages(
  bookId: string,
  currentChapter: Chapter | null,
) {
  const [pages, setPages] = useState<Page[]>([]);
  const [isLoading, setIsLoading] = useState(false);


  useEffect(() => {
    if (!currentChapter) return;
    let cancelled = false;
    setIsLoading(true);
    const load = async () => {
      const ps = await fetchPagesByChapter(currentChapter.id);
      if (cancelled) return;
      setPages(ps);
      setIsLoading(false);
    };
    void load();
    return () => {
      cancelled = true;
      setIsLoading(false);
    };
  }, [bookId, currentChapter]);

  const visiblePages = useMemo(() => {
    const firstOcrUnreadyIdx = pages.findIndex(
      (p) => p.ocrStatus !== "completed",
    );
    return firstOcrUnreadyIdx === -1
      ? pages
      : pages.slice(0, firstOcrUnreadyIdx + 1);
  }, [pages]);

  return { pages, setPages, visiblePages, isLoading };
}
