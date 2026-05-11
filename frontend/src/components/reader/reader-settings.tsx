"use client";

import { useEffect, useRef, useState } from "react";
import { Settings } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import { useLocalStorage } from "@/hooks/use-local-storage";


export interface ReaderPrefs {
  fontSize: "sm" | "base" | "lg";
  lineHeight: "relaxed" | "loose";
}

const DEFAULT_PREFS: ReaderPrefs = { fontSize: "base", lineHeight: "relaxed" };

export function useReaderPrefs() {
  const [prefs, setPrefs] = useLocalStorage<ReaderPrefs>(
    "bookllm:reader-prefs",
    DEFAULT_PREFS,
  );
  const updatePrefs = (patch: Partial<ReaderPrefs>) =>
    setPrefs({ ...prefs, ...patch });
  return { prefs, updatePrefs };
}

export function fontSizeClass(f: ReaderPrefs["fontSize"]) {
  return { sm: "text-sm", base: "text-base", lg: "text-lg" }[f];
}
export function lineHeightClass(l: ReaderPrefs["lineHeight"]) {
  return { relaxed: "leading-relaxed", loose: "leading-loose" }[l];
}


interface ReaderSettingsProps {
  prefs: ReaderPrefs;
  onUpdate: (patch: Partial<ReaderPrefs>) => void;
}

export function ReaderSettings({ prefs, onUpdate }: ReaderSettingsProps) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (
        containerRef.current &&
        !containerRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  return (
    <div ref={containerRef} className="relative shrink-0">
      <Button
        variant="ghost"
        size="icon"
        className="h-8 w-8"
        title={t("reader.typographySettings")}
        onClick={() => setOpen((v) => !v)}
      >
        <Settings className="h-4 w-4" />
      </Button>

      {open && (
        <div className="absolute right-0 top-10 z-50 w-52 rounded-lg border border-border bg-card shadow-lg p-4 space-y-4">
          <div className="space-y-2">
            <p className="text-xs font-medium text-muted-foreground">
              {t("reader.fontSize")}
            </p>
            <div className="flex gap-1">
              {(["sm", "base", "lg"] as const).map((size) => (
                <button
                  key={size}
                  onClick={() => onUpdate({ fontSize: size })}
                  className={cn(
                    "flex-1 rounded-md py-1.5 text-xs font-medium transition-colors",
                    prefs.fontSize === size
                      ? "bg-primary text-primary-foreground"
                      : "bg-secondary text-secondary-foreground hover:bg-secondary/80",
                  )}
                >
                  {size === "sm"
                    ? t("reader.fontSmall")
                    : size === "base"
                      ? t("reader.fontMedium")
                      : t("reader.fontLarge")}
                </button>
              ))}
            </div>
          </div>

          <div className="space-y-2">
            <p className="text-xs font-medium text-muted-foreground">
              {t("reader.lineHeight")}
            </p>
            <div className="flex gap-1">
              {(["relaxed", "loose"] as const).map((lh) => (
                <button
                  key={lh}
                  onClick={() => onUpdate({ lineHeight: lh })}
                  className={cn(
                    "flex-1 rounded-md py-1.5 text-xs font-medium transition-colors",
                    prefs.lineHeight === lh
                      ? "bg-primary text-primary-foreground"
                      : "bg-secondary text-secondary-foreground hover:bg-secondary/80",
                  )}
                >
                  {lh === "relaxed"
                    ? t("reader.lineComfort")
                    : t("reader.lineLoose")}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
