"use client";

import { Eye, EyeOff } from "lucide-react";
import { Input } from "@/components/ui/input";
import { useI18n } from "@/lib/i18n";

export function maskApiKeyForDisplay(apiKey: string) {
  if (!apiKey) return "";
  return apiKey.length > 14 ? `${apiKey.slice(0, 6)}••••••${apiKey.slice(-4)}` : "••••••";
}

export function ApiKeyField({
  value,
  onChange,
  configured,
  mask,
  show,
  onToggleShow,
  placeholder,
  testId,
}: {
  value: string;
  onChange: (value: string) => void;
  configured: boolean;
  mask: string;
  show: boolean;
  onToggleShow: () => void;
  placeholder?: string;
  testId?: string;
}) {
  const { t } = useI18n();
  return (
    <>
      <div className="relative">
        <Input
          type={show ? "text" : "password"}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={mask || placeholder || t("llm.apiKeyPlaceholder")}
          className="pr-9 font-mono text-sm"
        />
        <button
          type="button"
          data-testid={testId}
          className="absolute right-2.5 top-1/2 -translate-y-1/2 text-muted-foreground transition-colors hover:text-foreground"
          onClick={onToggleShow}
        >
          {show ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}
        </button>
      </div>
      <p className="font-mono text-[11px] text-muted-foreground/80">
        {value
          ? maskApiKeyForDisplay(value)
          : configured
            ? t("llm.apiKeyConfigured")
            : t("llm.apiKeyNotSet")}
      </p>
    </>
  );
}

