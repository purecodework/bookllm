"use client";

import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n";

export function SettingsSaveBar({
  saving,
  disabled,
  error,
  success,
  onSave,
}: {
  saving: boolean;
  disabled: boolean;
  error: string;
  success: string;
  onSave: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="sticky bottom-20 z-10 flex flex-wrap items-center gap-3 rounded-xl border border-white/70 bg-white/75 px-3 py-3 shadow-sm backdrop-blur-xl md:static md:border-0 md:bg-transparent md:p-0 md:shadow-none md:backdrop-blur-none dark:border-white/10 dark:bg-neutral-900/75 md:dark:bg-transparent">
      <Button onClick={onSave} disabled={saving || disabled} className="min-w-[100px]">
        {saving && <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" />}
        {t("settings.saveButton")}
      </Button>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {success && <p className="text-sm text-success">{t("settings.savedShort")}</p>}
      {disabled && !saving && <p className="text-xs text-muted-foreground">{t("settings.configureFirst")}</p>}
    </div>
  );
}

