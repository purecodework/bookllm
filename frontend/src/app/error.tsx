"use client";

import { AlertTriangle, RefreshCw, Home } from "lucide-react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n";

export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  const { t } = useI18n();

  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-8">
      <div className="flex flex-col items-center text-center max-w-md">
        <div className="h-16 w-16 rounded-full bg-destructive/10 flex items-center justify-center mb-6">
          <AlertTriangle className="h-8 w-8 text-destructive" />
        </div>

        <h1 className="text-xl font-semibold text-foreground mb-2">
          {t("error.title")}
        </h1>
        <p className="text-sm text-muted-foreground mb-2">
          {t("error.description")}
        </p>

        {process.env.NODE_ENV === "development" && (
          <pre className="mt-3 mb-6 w-full rounded-lg border border-border bg-muted p-4 text-left text-xs text-muted-foreground overflow-auto max-h-40">
            {error.message}
            {error.digest ? `\nDigest: ${error.digest}` : ""}
          </pre>
        )}

        <div className="flex items-center gap-3 mt-4">
          <Button variant="outline" onClick={reset} className="gap-2">
            <RefreshCw className="h-4 w-4" />
            {t("common.retry")}
          </Button>
          <Button asChild className="gap-2">
            <Link href="/">
              <Home className="h-4 w-4" />
              {t("error.backHome")}
            </Link>
          </Button>
        </div>
      </div>
    </div>
  );
}
