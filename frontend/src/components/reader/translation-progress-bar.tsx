"use client";

import { Loader2, CheckCircle2, AlertCircle, Clock } from "lucide-react";
import { Progress } from "@/components/ui/progress";
import { Badge } from "@/components/ui/badge";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import { computeEta } from "@/lib/translation-eta";
import { formatDuration } from "@/lib/duration-format";

interface GlossaryProgress {
  completedSections: number;
  totalSections: number;
  estimatedRemainingMs?: number;
}

interface ChapterStatus {
  id: string;
  status: string;
  translationProgress: number;
  translationStartedAt?: string | null;
  tokensPerSecond?: number | null;
}

interface TranslationProgressBarProps {
  chapter: ChapterStatus | null;
  isPaused?: boolean;
  isStreamingTranslation?: boolean;
  glossaryExtracting?: boolean;
  glossaryProgress?: GlossaryProgress | null;
}

export function TranslationProgressBar({
  chapter,
  isPaused = false,
  isStreamingTranslation = false,
  glossaryExtracting = false,
  glossaryProgress = null,
}: TranslationProgressBarProps) {
  const { locale, t } = useI18n();

  if (chapter?.status === "completed") {
    return (
      <Badge variant="success" className="gap-1 text-xs">
        <CheckCircle2 className="h-3 w-3" />
        {t("reader.progress.completed")}
      </Badge>
    );
  }

  if (!chapter) return null;

  const statusConfig = {
    pending: {
      icon: Clock,
      color: "text-muted-foreground",
      label: t("reader.progress.pending"),
    },
    processing: {
      icon: Loader2,
      color: "text-primary",
      label: t("reader.progress.processing"),
    },
    completed: {
      icon: CheckCircle2,
      color: "text-success",
      label: t("reader.progress.completed"),
    },
    failed: {
      icon: AlertCircle,
      color: "text-destructive",
      label: t("reader.progress.failed"),
    },
  };

  const statusKey = chapter.status as keyof typeof statusConfig;
  const cfg = statusConfig[statusKey] ?? statusConfig.pending;
  const Icon = cfg.icon;
  const isProcessing = statusKey === "processing";
  const active = isProcessing && !isPaused;

  const glossaryPercent =
    glossaryExtracting && glossaryProgress?.totalSections
      ? Math.round((glossaryProgress.completedSections / glossaryProgress.totalSections) * 100)
      : null;

  const eta = active
    ? computeEta(
        chapter.translationProgress,
        chapter.translationStartedAt,
        Date.now(),
        locale,
      )
    : { percentPerMin: undefined, etaSeconds: undefined, etaLabel: undefined };

  const speedLabel =
    active && isStreamingTranslation && chapter.tokensPerSecond != null && chapter.tokensPerSecond > 0
      ? `~${chapter.tokensPerSecond.toFixed(1)} tok/s`
      : undefined;

  const statusLabel =
    glossaryExtracting && glossaryProgress?.totalSections
      ? `${t("reader.progress.glossaryExtracting")} ${glossaryProgress.completedSections}/${glossaryProgress.totalSections}`
    : glossaryExtracting ? t("reader.progress.glossaryExtracting")
    : isPaused && isProcessing ? t("reader.progress.paused")
    : cfg.label;
  const shownProgress = glossaryPercent ?? chapter.translationProgress;
  const glossaryEtaLabel =
    glossaryExtracting && glossaryProgress?.estimatedRemainingMs
      ? formatDuration(Math.ceil(glossaryProgress.estimatedRemainingMs / 1000), locale)
      : undefined;

  return (
    <div className="flex items-center gap-2 min-w-[220px]">
      <Icon
        className={cn("h-4 w-4 shrink-0", cfg.color, (active || glossaryExtracting) && "animate-spin")}
      />

      <div className="flex-1 space-y-1">
        <div className="flex items-center justify-between">
          <span className="text-[11px] text-muted-foreground">
            {statusLabel}
          </span>
          <span className="text-xs text-muted-foreground tabular-nums">
            {shownProgress}%
          </span>
        </div>
        <Progress value={shownProgress} className="h-1" />
        {(speedLabel || eta.etaLabel || glossaryEtaLabel) && (
          <div className="flex items-center justify-between">
            <span
              data-testid="translation-speed"
              className="text-[10px] tabular-nums text-muted-foreground/50 font-mono"
            >
              {speedLabel}
            </span>
            {(glossaryEtaLabel || eta.etaLabel) && (
              <span
                data-testid="translation-eta"
                className="text-[10px] tabular-nums text-muted-foreground/50 font-mono"
              >
                {glossaryEtaLabel ?? eta.etaLabel}
              </span>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
