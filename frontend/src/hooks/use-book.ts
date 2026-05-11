"use client";

import { useState, useEffect } from "react";
import {
  fetchBook,
  fetchChaptersByBook,
  type Book,
  type Chapter,
} from "@/lib/api";

export function useBook(bookId: string) {
  const [book, setBook] = useState<Book | null>(null);
  const [chapters, setChapters] = useState<Chapter[]>([]);
  const [currentChapter, setCurrentChapter] = useState<Chapter | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const applyChapters = (chs: Chapter[]) => {
    setChapters(chs);
    setCurrentChapter((prev) => {
      if (chs.length === 0) return null;
      if (!prev) return chs[0];
      return chs.find((c) => c.id === prev.id) ?? chs[0];
    });
  };

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const [b, chs] = await Promise.all([
          fetchBook(bookId),
          fetchChaptersByBook(bookId),
        ]);
        if (cancelled) return;
        setBook(b);
        applyChapters(chs);
      } catch (e) {
        if (!cancelled)
          setError(e instanceof Error ? e.message : "Failed to load book");
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void load();
    return () => {
      cancelled = true;
    };
  }, [bookId]);

  const canTranslate = chapters.some(
    (c) => c.status !== "completed" && (c._count?.pages ?? 0) > 0,
  );

  return {
    book,
    chapters,
    setChapters,
    currentChapter,
    setCurrentChapter,
    loading,
    error,
    canTranslate,
  };
}
