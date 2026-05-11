import { Zap } from "lucide-react";
import { useI18n } from "@/lib/i18n";

export function TtftBadge({ ttftMs }: { ttftMs: number | null }) {
  const { t } = useI18n();
  if (ttftMs === null) return null;
  return (
    <div className="fixed top-[64px] left-1/2 -translate-x-1/2 z-50 pointer-events-none">
      <div className="flex items-center gap-1.5 bg-card/95 border border-border backdrop-blur shadow-lg rounded-full px-3 py-1.5 text-xs text-foreground animate-in fade-in slide-in-from-top-2 duration-300">
        <Zap className="h-3 w-3 text-primary" />
        {t("reader.ttft")} {(ttftMs / 1000).toFixed(1)}s
      </div>
    </div>
  );
}
