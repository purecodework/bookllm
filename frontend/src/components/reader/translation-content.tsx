"use client";

import { useState, useEffect } from "react";
import { Loader2, AlertCircle } from "lucide-react";
import { TextBlocks } from "@/components/reader/text-blocks";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import type { Page } from "@/lib/api";

interface TranslationContentProps {
  page: Page;
  fontSize: string;
  lineHeight: string;
  streamedText?: string;
  isConnected?: boolean;
  bookId?: string;
}

export function TranslationContent({
  page,
  fontSize,
  lineHeight,
  streamedText,
  isConnected,
  bookId,
}: TranslationContentProps) {
  const { t } = useI18n();
  const [prefillSec, setPrefillSec] = useState(0);
  const hasStreamedText = Boolean(streamedText);

  useEffect(() => {
    if (!isConnected || hasStreamedText) {
      setPrefillSec(0);
      return;
    }
    const start = Date.now();
    const t = setInterval(
      () => setPrefillSec((Date.now() - start) / 1000),
      100,
    );
    return () => clearInterval(t);
  }, [hasStreamedText, isConnected]);

  if (page.targetText) {
    return (
      <TextBlocks
        text={page.targetText}
        fontSize={fontSize}
        lineHeight={lineHeight}
        bookId={bookId}
      />
    );
  }

  if (page.translationStatus === "processing") {
    if (streamedText) {
      return (
        <div className={cn(fontSize, lineHeight)}>
          <TextBlocks
            text={streamedText}
            fontSize={fontSize}
            lineHeight={lineHeight}
            bookId={bookId}
          />
          <span className="inline-block w-0.5 h-[1em] bg-primary/70 animate-pulse ml-0.5 align-text-bottom rounded-sm" />
        </div>
      );
    }
    return (
      <div className="flex flex-col items-center justify-center min-h-[200px] gap-3 text-center">
        <Loader2 className="h-8 w-8 text-primary animate-spin" />
        {isConnected ? (
          <>
            <p className="text-sm font-medium">LLM Prefill</p>
            <p className="text-xs text-muted-foreground/70 font-mono tabular-nums">
              {prefillSec.toFixed(1)}s
            </p>
          </>
        ) : (
          <>
            <p className="text-sm font-medium">{t("reader.translating")}</p>
            <p className="text-xs text-muted-foreground">
              {t("reader.localLlmProcessing")}
            </p>
          </>
        )}
      </div>
    );
  }

  if (page.translationStatus === "failed") {
    return (
      <div className="flex flex-col items-center justify-center min-h-[120px] gap-3 text-center px-4">
        <AlertCircle className="h-6 w-6 text-destructive/70" />
        <div className="space-y-1">
          <p className="text-sm text-destructive">
            {t("reader.translationFailed")}
          </p>
          {page.errorMessage && (
            <p className="text-[11px] text-muted-foreground/70 font-mono break-all max-w-xs">
              {page.errorMessage}
            </p>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center justify-center min-h-[200px] gap-3 text-center">
      <p className="text-sm text-muted-foreground">
        {t("reader.notTranslatedYet")}
      </p>
    </div>
  );
}
