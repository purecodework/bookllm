"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { FieldLabel } from "@/components/settings/shared/field-label";
import { useI18n } from "@/lib/i18n";

export function TranslationParamsCard({
  inputTokenBudget,
  setInputTokenBudget,
  concurrencyValue,
  setConcurrency,
}: {
  inputTokenBudget: string;
  setInputTokenBudget: (value: string) => void;
  concurrencyValue: number;
  setConcurrency: (value: string) => void;
}) {
  const { t } = useI18n();
  return (
    <Card>
      <CardHeader className="border-b border-border pb-3">
        <CardTitle className="text-sm font-semibold">{t("settings.translationParamsTitle")}</CardTitle>
        <p className="mt-0.5 text-xs text-muted-foreground">{t("settings.translationParamsDesc")}</p>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <FieldLabel label={t("settings.inputTokenBudget")} hint={t("settings.tokenRecommended")} />
            <Input
              type="number"
              min={1024}
              value={inputTokenBudget}
              onChange={(e) => setInputTokenBudget(e.target.value)}
              className="font-mono text-sm"
            />
            <p className="text-[11px] text-muted-foreground/80">{t("settings.inputTokenBudgetHelp")}</p>
          </div>

          <div className="space-y-1.5">
            <FieldLabel label={t("settings.concurrency")} hint="1 ~ 32" />
            <div className="space-y-2">
              <input
                type="range"
                min={1}
                max={32}
                step={1}
                value={concurrencyValue}
                onChange={(e) => setConcurrency(e.target.value)}
                className="glass-range w-full"
              />
              <div className="font-mono text-xs tabular-nums text-muted-foreground">{concurrencyValue}</div>
            </div>
            <p className="text-[11px] text-muted-foreground/80">{t("settings.concurrencyHelp")}</p>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
