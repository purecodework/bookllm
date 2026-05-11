"use client";

import { useState, useCallback, useRef } from "react";
import {
  startBookTranslation,
  fetchChaptersByBook,
  type Chapter,
} from "@/lib/api";
import { useI18n } from "@/lib/i18n";

export function useStartTranslation(bookId: string) {
  const { t } = useI18n();
  const [translating, setTranslating] = useState(false);
  const [error, setError] = useState("");
  const inFlightRef = useRef(false);

  const trigger = useCallback(async (): Promise<Chapter[] | null> => {
    if (inFlightRef.current) return null;
    inFlightRef.current = true;
    setTranslating(true);
    setError("");
    try {
      await startBookTranslation(bookId);
      return await fetchChaptersByBook(bookId);
    } catch (e) {
      setError(e instanceof Error ? e.message : t("reader.startFailed"));
      return null;
    } finally {
      inFlightRef.current = false;
      setTranslating(false);
    }
  }, [bookId, t]);

  return { translating, error, trigger };
}
