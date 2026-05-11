"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import {
  BookOpen,
  Upload,
  Settings,
  Cpu,
  ChevronRight,
  RefreshCw,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useI18n } from "@/lib/i18n";
import { fetchHealth, providerLabel, type HealthReport } from "@/lib/api";
import { LlmSettingsDialog } from "@/components/settings/llm-settings-dialog";
import { Separator } from "@/components/ui/separator";
import { Button } from "@/components/ui/button";

let HEALTH_CACHE: HealthReport | null = null;
let HEALTH_CACHE_AT = 0;
const HEALTH_CACHE_TTL_MS = 30_000;

function LlmStatusWidget() {
  const { t } = useI18n();
  const [health, setHealth] = useState<HealthReport | null>(HEALTH_CACHE);
  const [loading, setLoading] = useState(!HEALTH_CACHE);
  const [dialogOpen, setDialogOpen] = useState(false);

  const load = async (silent = false) => {
    if (!silent) setLoading(true);
    try {
      const data = await fetchHealth();
      setHealth(data);
      HEALTH_CACHE = data;
      HEALTH_CACHE_AT = Date.now();
    } finally {
      if (!silent) setLoading(false);
    }
  };

  useEffect(() => {
    const hasFreshCache =
      HEALTH_CACHE && Date.now() - HEALTH_CACHE_AT < HEALTH_CACHE_TTL_MS;
    if (hasFreshCache) {
      setHealth(HEALTH_CACHE);
      setLoading(false);
      void load(true);
    } else {
      void load();
    }

    const timer = setInterval(() => {
      void load(true);
    }, 30_000);
    return () => clearInterval(timer);
  }, []);

  const llm = health?.services?.llm;
  const llmProvider = health?.services?.llm?.provider;
  const isOnline = llm?.status === "ok";
  const modelCount = llm?.modelCount ?? llm?.models?.length ?? 0;
  const platform = providerLabel(llm?.provider);
  const providerTitle = llmProvider
    ? providerLabel(llmProvider)
    : t("sidebar.unspecifiedProvider");
  const activeModel = llm?.activeModel;

  return (
    <>
      <div
        onClick={() => setDialogOpen(true)}
        className="w-full flex items-start gap-2 rounded-xl px-2.5 py-2.5 hover:bg-secondary/80 transition-colors text-left group border border-transparent hover:border-border/80 hover:shadow-[var(--glass-shadow-1)]"
        title={t("sidebar.configureConnection")}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") setDialogOpen(true);
        }}
      >
        <Cpu className="h-4 w-4 text-muted-foreground shrink-0 mt-0.5" />
        <div className="flex-1 min-w-0">
          <div className="flex items-center justify-between gap-1">
            <span
              className="min-w-0 flex-1 truncate text-left text-[11px] font-semibold text-foreground"
            >
              {providerTitle}
            </span>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="h-6 w-6 shrink-0 opacity-70 transition-opacity hover:opacity-100 group-hover:opacity-100"
              title={t("sidebar.refreshConnection")}
              aria-label={t("sidebar.refreshConnection")}
              onClick={(e) => {
                e.stopPropagation();
                void load();
              }}
            >
              <RefreshCw
                className={cn(
                  "h-3 w-3 text-muted-foreground",
                  loading && "animate-spin",
                )}
              />
            </Button>
          </div>

          {loading && !health ? (
            <p className="text-xs text-muted-foreground mt-0.5">
              {t("common.checking")}
            </p>
          ) : (
            <>
              <div className="flex items-center gap-1.5 mt-0.5">
                <span
                  className={cn(
                    "h-1.5 w-1.5 rounded-full shrink-0",
                    isOnline ? "bg-success" : "bg-destructive",
                  )}
                />
                <p className="text-xs text-muted-foreground truncate">
                  {isOnline
                    ? t("sidebar.ready", { platform })
                    : t("sidebar.offlineConfig")}
                </p>
              </div>
              {isOnline && activeModel && (
                <p
                  className="text-xs text-primary/80 truncate mt-0.5 font-mono"
                  title={activeModel}
                >
                  {activeModel}
                </p>
              )}
              {isOnline && modelCount > 0 && (
                <p className="text-xs text-muted-foreground mt-0.5">
                  {t("sidebar.modelsCount", { count: modelCount })}
                </p>
              )}
            </>
          )}
        </div>
      </div>

      <LlmSettingsDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        onSaved={load}
      />
    </>
  );
}

function MobileLlmButton() {
  const { t } = useI18n();
  const [dialogOpen, setDialogOpen] = useState(false);

  return (
    <>
      <button
        type="button"
        onClick={() => setDialogOpen(true)}
        className="flex h-11 min-w-16 flex-col items-center justify-center gap-0.5 rounded-xl px-3 text-[10px] font-medium text-muted-foreground transition-colors hover:bg-secondary/80 hover:text-foreground"
      >
        <Cpu className="h-4 w-4 shrink-0" />
        <span className="max-w-16 truncate">{t("sidebar.modelConnection")}</span>
      </button>
      <LlmSettingsDialog open={dialogOpen} onOpenChange={setDialogOpen} />
    </>
  );
}

export function Sidebar() {
  const { t } = useI18n();
  const pathname = usePathname();
  const navItems = [
    { label: t("sidebar.library"), href: "/", icon: BookOpen },
    { label: t("sidebar.upload"), href: "/upload", icon: Upload },
  ];
  const bottomNavItems = [
    { label: t("sidebar.settings"), href: "/settings", icon: Settings },
  ];

  return (
    <>
      <aside className="glass-nav-shell fixed left-0 top-0 z-30 hidden h-screen w-[var(--sidebar-width)] flex-col rounded-none border-y-0 border-l-0 lg:flex">
        <Link href="/">
          <div className="flex h-[52px] items-center gap-2.5 border-b border-sidebar-border px-4">
            <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary shadow-[var(--glass-shadow-1)]">
              <BookOpen className="h-4 w-4 text-white" />
            </div>
            <span className="text-base font-semibold text-foreground tracking-tight">
              BookLLM
            </span>
          </div>
        </Link>

        <nav className="flex-1 overflow-y-auto px-2 py-3">
          <div className="mb-1 px-2 text-[10px] font-semibold text-muted-foreground uppercase tracking-[0.08em]">
            {t("sidebar.navigation")}
          </div>
          <ul className="space-y-0.5">
            {navItems.map((item) => {
              const isActive = pathname === item.href;
              return (
                <li key={item.href}>
                  <Link
                    href={item.href}
                    className={cn(
                      "group flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium transition-colors",
                      isActive
                        ? "glass-active text-primary"
                        : "text-muted-foreground hover:bg-secondary/80 hover:text-foreground",
                    )}
                  >
                    <item.icon
                      className={cn(
                        "h-4 w-4 shrink-0",
                        isActive
                          ? "text-primary"
                          : "text-muted-foreground group-hover:text-foreground",
                      )}
                    />
                    {item.label}
                    {isActive && (
                      <ChevronRight className="ml-auto h-3 w-3 text-primary" />
                    )}
                  </Link>
                </li>
              );
            })}
          </ul>
        </nav>

        <div className="border-t border-sidebar-border px-2 py-3 space-y-1">
          <LlmStatusWidget />
          <Separator className="my-1" />

          {bottomNavItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium text-muted-foreground hover:bg-secondary/80 hover:text-foreground transition-colors"
            >
              <item.icon className="h-4 w-4 shrink-0" />
              {item.label}
            </Link>
          ))}
        </div>
      </aside>

      <nav className="glass-bottom-nav fixed inset-x-3 bottom-3 z-40 flex h-14 items-center justify-around rounded-2xl px-2 lg:hidden">
        {[...navItems].map((item) => {
          const isActive = pathname === item.href;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex h-11 min-w-16 flex-col items-center justify-center gap-0.5 rounded-xl px-3 text-[10px] font-medium transition-colors",
                isActive
                  ? "glass-active text-primary"
                  : "text-muted-foreground hover:bg-secondary/80 hover:text-foreground",
              )}
            >
              <item.icon className="h-4 w-4 shrink-0" />
              <span className="max-w-16 truncate">{item.label}</span>
            </Link>
          );
        })}
        <MobileLlmButton />
        {bottomNavItems.map((item) => {
          const isActive = pathname === item.href;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex h-11 min-w-16 flex-col items-center justify-center gap-0.5 rounded-xl px-3 text-[10px] font-medium transition-colors",
                isActive
                  ? "glass-active text-primary"
                  : "text-muted-foreground hover:bg-secondary/80 hover:text-foreground",
              )}
            >
              <item.icon className="h-4 w-4 shrink-0" />
              <span className="max-w-16 truncate">{item.label}</span>
            </Link>
          );
        })}
      </nav>
    </>
  );
}
