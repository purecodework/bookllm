"use client";

import Link from "next/link";
import { Search, Upload, Sun, Moon } from "lucide-react";
import { useTheme } from "@/lib/use-theme";
import { useI18n } from "@/lib/i18n";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

interface HeaderProps {
  title?: string;
  searchValue?: string;
  onSearchChange?: (value: string) => void;
  searchPlaceholder?: string;
}

export function Header({
  title,
  searchValue,
  onSearchChange,
  searchPlaceholder,
}: HeaderProps) {
  const { t } = useI18n();
  const { theme, setTheme } = useTheme();
  const searchEnabled = typeof onSearchChange === "function";
  const effectivePlaceholder =
    searchPlaceholder ?? t("header.searchPlaceholder");

  return (
    <header
      className="glass-toolbar fixed left-0 right-0 top-0 z-20 flex h-[var(--header-height)] items-center gap-3 border-x-0 border-t-0 px-3 md:px-6 lg:left-[var(--sidebar-width)]"
    >
      {title && (
        <h1 className="hidden text-sm font-medium text-muted-foreground sm:block shrink-0">
          {title}
        </h1>
      )}

      <div className="relative flex-1 max-w-sm">
        <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
        <Input
          type="search"
          placeholder={effectivePlaceholder}
          className="pl-9 h-9 text-sm"
          value={searchValue ?? ""}
          onChange={(e) => onSearchChange?.(e.target.value)}
          disabled={!searchEnabled}
        />
      </div>

      <div className="flex-1" />

      <Button
        variant="ghost"
        size="icon"
        className="h-9 w-9 shrink-0"
        onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
        title={
          theme === "dark"
            ? t("header.switchToLight")
            : t("header.switchToDark")
        }
      >
        {theme === "dark" ? (
          <Sun className="h-4 w-4" />
        ) : (
          <Moon className="h-4 w-4" />
        )}
      </Button>

      <Button asChild size="sm" className="hidden gap-1.5 shrink-0 sm:inline-flex">
        <Link href="/upload">
          <Upload className="h-4 w-4" />
          {t("header.upload")}
        </Link>
      </Button>
    </header>
  );
}
