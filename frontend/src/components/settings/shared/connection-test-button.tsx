"use client";

import { AlertCircle, CheckCircle2, Loader2, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { type TestState } from "@/components/settings/types";
import { useI18n } from "@/lib/i18n";

export function ConnectionTestButton({
  state,
  error,
  disabled,
  onTest,
}: {
  state: TestState;
  error: string;
  disabled: boolean;
  onTest: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="glass-panel rounded-xl p-2">
      <Button
        variant="outline"
        size="sm"
        className="w-full gap-2 border-transparent bg-transparent"
        disabled={state === "loading" || disabled}
        onClick={onTest}
      >
        {state === "loading" ? (
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
        ) : state === "ok" ? (
          <CheckCircle2 className="h-3.5 w-3.5 text-success" />
        ) : state === "error" ? (
          <AlertCircle className="h-3.5 w-3.5 text-destructive" />
        ) : (
          <RefreshCw className="h-3.5 w-3.5" />
        )}
        {state === "loading" ? t("common.connecting") : t("llm.testConnection")}
      </Button>
      {state === "error" && (
        <p className="mt-2 break-words px-2 pb-1 text-xs text-destructive">
          {error}
        </p>
      )}
    </div>
  );
}

