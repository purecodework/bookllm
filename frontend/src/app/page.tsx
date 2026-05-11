"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AppShell } from "@/components/layout/app-shell";
import {
  BookCardSkeleton,
  BookLibrary,
} from "@/components/home/book-library";
import { fetchBooks, type Book } from "@/lib/api";
import { getApiBase } from "@/lib/api-base";
import { useI18n } from "@/lib/i18n";
import { parseSseJson } from "@/lib/sse";

export default function HomePage() {
  const { t } = useI18n();
  const [books, setBooks] = useState<Book[]>([]);
  const [searchTerm, setSearchTerm] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setError(null);
      const data = await fetchBooks();
      setBooks(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : t("home.loadFailed"));
    } finally {
      setLoading(false);
    }
  }, [t]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    const es = new EventSource(`${getApiBase()}/events/books`);
    let active = true;
    es.onmessage = (event) => {
      if (!active) return;
      const data = parseSseJson<{
        type: string;
        payload?: {
          bookId: string;
          status: string;
          translationProgress: number;
        };
      }>(event.data);
      if (data?.type !== "book_state" || !data.payload) return;
      const payload = data.payload;

      setBooks((prev) => {
        const idx = prev.findIndex((book) => book.id === payload.bookId);
        if (idx === -1) return prev;
        const current = prev[idx];
        if (
          current.status === payload.status &&
          (current.translationProgress ?? 0) === payload.translationProgress
        ) {
          return prev;
        }
        const next = [...prev];
        next[idx] = {
          ...current,
          status: payload.status,
          translationProgress: payload.translationProgress,
        };
        return next;
      });
    };
    return () => {
      active = false;
      es.onmessage = null;
      es.close();
    };
  }, []);

  const normalizedSearch = searchTerm.trim().toLowerCase();
  const filteredBooks = useMemo(
    () =>
      normalizedSearch
        ? books.filter((book) =>
            book.title.toLowerCase().includes(normalizedSearch),
          )
        : books,
    [books, normalizedSearch],
  );

  return (
    <AppShell
      headerSearchValue={searchTerm}
      onHeaderSearchChange={setSearchTerm}
      headerSearchPlaceholder={t("header.searchPlaceholder")}
    >
      <div className="mx-auto w-full max-w-7xl p-4 md:p-8">
        <div className="mb-6">
          <h1 className="text-[24px] font-semibold text-foreground tracking-tight">
            {t("home.title")}
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            {loading
              ? t("common.loading")
              : t("home.count", { count: filteredBooks.length })}
          </p>
        </div>

        {error && (
          <div className="mb-6 rounded-lg border border-destructive/50 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            {t("home.backendFailedPrefix")}
            {error}
            <button className="ml-2 underline" onClick={load}>
              {t("common.retry")}
            </button>
          </div>
        )}

        {loading ? (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {Array.from({ length: 8 }).map((_, i) => (
              <BookCardSkeleton key={i} />
            ))}
          </div>
        ) : (
          <BookLibrary
            books={filteredBooks}
            normalizedSearch={normalizedSearch}
            onDelete={(id) =>
              setBooks((prev) => prev.filter((book) => book.id !== id))
            }
          />
        )}
      </div>
    </AppShell>
  );
}
