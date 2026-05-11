"use client";

import { useI18n } from "@/lib/i18n";

export function TokenCostBadge() {
  const { t } = useI18n();
  return (
    <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-2 py-0.5 text-[10px] font-medium tracking-normal text-amber-700 dark:text-amber-300">
      {t("settings.sidekickBadge")}
    </span>
  );
}

export function SlowHighCostBadge() {
  const { t } = useI18n();
  return (
    <span className="rounded-full border border-rose-500/30 bg-rose-500/10 px-2 py-0.5 text-[10px] font-medium tracking-normal text-rose-700 dark:text-rose-300">
      {t("settings.slowHighCostBadge")}
    </span>
  );
}
