"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { GlassToggle } from "@/components/ui/glass-toggle";
import { ModelSourceSelector } from "@/components/settings/shared/model-source-selector";
import {
  SlowHighCostBadge,
  TokenCostBadge,
} from "@/components/settings/shared/token-cost-badge";
import { type ModelSource } from "@/components/settings/types";
import { useI18n } from "@/lib/i18n";

export function BookGlossaryCard({
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
          <span>{t("settings.bookGlossary")}</span>
          <TokenCostBadge />
          <SlowHighCostBadge />
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4 pt-4">
        <GlassToggle
          checked={enabled}
          onChange={onEnabledChange}
          label={t("settings.bookGlossaryToggle")}
        />
        {enabled && (
          <ModelSourceSelector
            value={modelSource}
            onChange={onModelSourceChange}
            sidekickReady={sidekickReady}
            label={t("settings.bookGlossaryModel")}
            sidekickHint={""}
          />
        )}
      </CardContent>
    </Card>
  );
}
