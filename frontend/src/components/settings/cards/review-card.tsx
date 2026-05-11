"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { GlassToggle } from "@/components/ui/glass-toggle";
import { ModelSourceSelector } from "@/components/settings/shared/model-source-selector";
import { TokenCostBadge } from "@/components/settings/shared/token-cost-badge";
import { type ModelSource } from "@/components/settings/types";
import { useI18n } from "@/lib/i18n";

export function ReviewCard({
  enabled,
  onEnabledChange,
  modelSource,
  onModelSourceChange,
  sidekickReady,
}: {
  enabled: boolean;
  onEnabledChange: (value: boolean) => void;
  modelSource: ModelSource;
  onModelSourceChange: (value: ModelSource) => void;
  sidekickReady: boolean;
}) {
  const { t } = useI18n();
  return (
    <Card>
      <CardHeader className="border-b border-border pb-3">
        <CardTitle className="flex items-center gap-2 text-sm font-semibold">
          <span>{t("settings.reviewTitle")}</span>
          <TokenCostBadge />
        </CardTitle>
        <p className="mt-0.5 text-xs text-muted-foreground">{t("settings.reviewDesc")}</p>
        <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">
          {t("settings.sidekickExperimentalWarning")}
        </p>
      </CardHeader>
      <CardContent className="space-y-4 pt-4">
        <GlassToggle checked={enabled} onChange={onEnabledChange} label={t("settings.reviewToggle")} />
        {enabled && (
          <ModelSourceSelector
            value={modelSource}
            onChange={onModelSourceChange}
            sidekickReady={sidekickReady}
            label={t("settings.reviewModel")}
            sidekickHint={t("settings.reviewModelSidekickHint")}
          />
        )}
      </CardContent>
    </Card>
  );
}

