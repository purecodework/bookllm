"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { GlassToggle } from "@/components/ui/glass-toggle";
import { ModelSourceSelector } from "@/components/settings/shared/model-source-selector";
import { TokenCostBadge } from "@/components/settings/shared/token-cost-badge";
import { type ModelSource } from "@/components/settings/types";
import { useI18n } from "@/lib/i18n";

export function CustomStyleCard({
  enabled,
  onEnabledChange,
  modelSource,
  onModelSourceChange,
  prompt,
  onPromptChange,
  sidekickReady,
}: {
  enabled: boolean;
  onEnabledChange: (value: boolean) => void;
  modelSource: ModelSource;
  onModelSourceChange: (value: ModelSource) => void;
  prompt: string;
  onPromptChange: (value: string) => void;
  sidekickReady: boolean;
}) {
  const { t } = useI18n();
  return (
    <Card>
      <CardHeader className="border-b border-border pb-3">
        <CardTitle className="flex items-center gap-2 text-sm font-semibold">
          <span>{t("settings.customStyle")}</span>
          <TokenCostBadge />
        </CardTitle>
        <p className="mt-0.5 text-xs text-muted-foreground">{t("settings.customStyleDesc")}</p>
        <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">{t("settings.customStyleWarning")}</p>
      </CardHeader>
      <CardContent className="space-y-4 pt-4">
        <GlassToggle checked={enabled} onChange={onEnabledChange} label={t("settings.customStyleToggle")} />
        {enabled && (
          <>
            <ModelSourceSelector
              value={modelSource}
              onChange={onModelSourceChange}
              sidekickReady={sidekickReady}
              label={t("settings.polishModel")}
              sidekickHint={t("settings.polishModelSidekickHint")}
            />
            <textarea
              value={prompt}
              onChange={(e) => onPromptChange(e.target.value)}
              placeholder={t("settings.stylePlaceholder")}
              maxLength={1000}
              className="min-h-[120px] w-full rounded-xl border border-border bg-background px-3 py-2 text-sm outline-none transition-colors focus:border-primary/50"
            />
            <p className="text-[11px] text-muted-foreground/80">{t("settings.customStyleHelp")}</p>
          </>
        )}
      </CardContent>
    </Card>
  );
}
