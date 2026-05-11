import { Loader2 } from "lucide-react";
import { TextBlocks } from "@/components/reader/text-blocks";
import { TranslationContent } from "@/components/reader/translation-content";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import type { Page } from "@/lib/api";

interface PageRowProps {
  page: Page;
  showDivider: boolean;
  splitRatio: number;
  isCollapsed: boolean;
  isDividerHovered: boolean;
  onDividerMouseDown: (e: React.MouseEvent) => void;
  onDividerHoverChange: (hovered: boolean) => void;
  fontSize: string;
  lineHeight: string;
  streamedText?: string;
  isConnected?: boolean;
  isReviewing?: boolean;
  isPolishing?: boolean;
  isTranslationOnly?: boolean;
  onRef: (el: HTMLDivElement | null) => void;
}

export function PageRow({
  page,
  showDivider,
  splitRatio,
  isCollapsed,
  isDividerHovered,
  onDividerMouseDown,
  onDividerHoverChange,
  fontSize,
  lineHeight,
  streamedText,
  isConnected,
  isReviewing = false,
  isPolishing = false,
  isTranslationOnly = false,
  onRef,
}: PageRowProps) {
  const { t } = useI18n();
  const isBlank = page.ocrStatus === "completed" && !page.sourceText?.trim();
  if (isBlank) return null;

  if (isTranslationOnly) {
    return (
      <div key={page.id} data-page-id={page.id} ref={onRef}>
        {showDivider && (
          <div className="mx-auto flex max-w-[780px] items-center gap-4 px-5 py-3 md:py-4">
            <div className="flex-1 h-px bg-border/20" />
            <span className="text-[11px] tabular-nums text-muted-foreground/35 font-mono select-none">
              {page.pageNumber}
            </span>
            <div className="flex-1 h-px bg-border/20" />
          </div>
        )}
        <div className="mx-auto max-w-[780px] px-5 py-4 md:px-8 md:py-5">
          <TranslationContent
            page={page}
            fontSize={fontSize}
            lineHeight={lineHeight}
            streamedText={streamedText}
            isConnected={isConnected}
            bookId={page.bookId}
          />
          {isReviewing && (
            <div className="mt-3 flex items-center gap-1.5 text-[11px] text-muted-foreground/60">
              <Loader2 className="h-3 w-3 animate-spin" />
              <span>{t("reader.reviewing")}</span>
            </div>
          )}
          {isPolishing && (
            <div className="mt-3 flex items-center gap-1.5 text-[11px] text-muted-foreground/60">
              <Loader2 className="h-3 w-3 animate-spin" />
              <span>{t("reader.polishing")}</span>
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div key={page.id} data-page-id={page.id} ref={onRef}>
      {showDivider && (
        <div
          className={cn(
            "flex items-center gap-4 px-5 md:px-10",
            isCollapsed ? "py-3 md:py-4" : "py-4 md:py-6",
          )}
        >
          <div className="flex-1 h-px bg-border/25" />
          <span className="text-[11px] tabular-nums text-muted-foreground/30 font-mono select-none">
            {page.pageNumber}
          </span>
          <div className="flex-1 h-px bg-border/25" />
        </div>
      )}

      <div className="flex flex-col md:flex-row">
        <div
          className={cn(
            "hidden shrink-0 overflow-hidden transition-[width] duration-200 ease-in-out md:block",
            isCollapsed && "hidden md:block md:w-0",
          )}
          style={{ width: isCollapsed ? 0 : `${splitRatio * 100}%` }}
        >
          <div className="px-5 py-8 md:px-8 md:py-10">
            {page.sourceText ? (
              <TextBlocks
                text={page.sourceText}
                fontSize={fontSize}
                lineHeight={lineHeight}
                bookId={page.bookId}
              />
            ) : (
              <div className="flex flex-col items-center justify-center min-h-[200px] gap-2">
                <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                <p className="text-sm text-muted-foreground">
                  {t("reader.ocrProcessing")}
                </p>
              </div>
            )}
          </div>
        </div>

        <div
          className="relative hidden w-2 flex-shrink-0 cursor-col-resize select-none group md:block"
          style={{ display: isCollapsed ? "none" : undefined }}
          onMouseDown={onDividerMouseDown}
          onMouseEnter={() => onDividerHoverChange(true)}
          onMouseLeave={() => onDividerHoverChange(false)}
        >
          <div
            className={cn(
              "absolute inset-y-0 left-1/2 -translate-x-1/2 w-px bg-border/30 transition-colors",
              isDividerHovered && "bg-primary/40",
            )}
          />
        </div>

        <div className="flex-1 overflow-hidden">
          <div
            className={cn(
              "px-5 py-6 md:px-8 md:py-10",
              isCollapsed && "max-w-[760px] mx-auto md:py-5",
            )}
          >
            <TranslationContent
              page={page}
              fontSize={fontSize}
              lineHeight={lineHeight}
              streamedText={streamedText}
              isConnected={isConnected}
              bookId={page.bookId}
            />
            {isReviewing && (
              <div className="mt-3 flex items-center gap-1.5 text-[11px] text-muted-foreground/60">
                <Loader2 className="h-3 w-3 animate-spin" />
                <span>{t("reader.reviewing")}</span>
              </div>
            )}
            {isPolishing && (
              <div className="mt-3 flex items-center gap-1.5 text-[11px] text-muted-foreground/60">
                <Loader2 className="h-3 w-3 animate-spin" />
                <span>{t("reader.polishing")}</span>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
