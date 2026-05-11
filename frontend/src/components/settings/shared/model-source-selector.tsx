"use client";

import { FieldLabel } from "@/components/settings/shared/field-label";
import { type ModelSource } from "@/components/settings/types";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";

export function ModelSourceSelector({
  value,
  onChange,
  sidekickReady,
  label,
  sidekickHint,
}: {
  value: ModelSource;
  onChange: (value: ModelSource) => void;
  sidekickReady: boolean;
  label: string;
  sidekickHint: string;
}) {
  const { t } = useI18n();
  return (
    <div className="space-y-1.5">
      <FieldLabel label={label} />
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        <button
          type="button"
          onClick={() => onChange("primary")}
          className={cn(
            "rounded-lg border px-3 py-2 text-left text-sm transition-colors",
            value === "primary"
              ? "border-primary/50 bg-primary/10 text-primary"
              : "border-border bg-background hover:bg-secondary",
          )}
        >
          {t("settings.modelSourcePrimary")}
        </button>
        <button
          type="button"
          disabled={!sidekickReady}
          onClick={() => onChange("sidekick")}
          className={cn(
            "rounded-lg border px-3 py-2 text-left text-sm transition-colors",
            !sidekickReady
              ? "cursor-not-allowed border-border/60 bg-secondary/20 text-muted-foreground"
              : value === "sidekick"
                ? "border-primary/50 bg-primary/10 text-primary"
                : "border-border bg-background hover:bg-secondary",
          )}
        >
          {t("settings.modelSourceSidekick")}
        </button>
      </div>
      {!sidekickReady && (
        <p className="text-[11px] text-amber-700/90 dark:text-amber-300/90">
          {sidekickHint}
        </p>
      )}
    </div>
  );
}

