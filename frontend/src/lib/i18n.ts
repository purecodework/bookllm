"use client";

import { useCallback, useEffect, useState } from "react";
import en from "@/lib/messages/en";
import zh from "@/lib/messages/zh";

const messageCatalog = { en, zh } as const;

export type AppLocale = keyof typeof messageCatalog;
type BaseMessageMap = typeof messageCatalog.en;
export type MessageKey = keyof BaseMessageMap;
type MessageMap = Record<MessageKey, string>;
type MessageParams = Record<string, string | number>;

const messages: Record<AppLocale, MessageMap> = messageCatalog;
const DEFAULT_LOCALE: AppLocale = "en";

export function detectLocale(input?: string): AppLocale {
  const normalized = (input ?? "").toLowerCase();
  const primaryTag = normalized.split("-")[0];
  if (primaryTag && primaryTag in messages) {
    return primaryTag as AppLocale;
  }
  return normalized.startsWith("zh") ? "zh" : DEFAULT_LOCALE;
}

export function detectBrowserLocale(): AppLocale {
  if (typeof navigator === "undefined") return DEFAULT_LOCALE;
  return detectLocale(navigator.language || navigator.languages?.[0] || "");
}

export function useAppLocale(): AppLocale {

  const [locale, setLocale] = useState<AppLocale>(DEFAULT_LOCALE);
  useEffect(() => {
    setLocale(detectBrowserLocale());
  }, []);
  return locale;
}

function interpolate(template: string, params?: MessageParams): string {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (_full, key: string) => {
    const value = params[key];
    return value === undefined ? `{${key}}` : String(value);
  });
}

export function t(
  locale: AppLocale,
  key: MessageKey,
  params?: MessageParams,
): string {
  return interpolate(messages[locale][key] ?? key, params);
}

export function languageName(code: string, locale: AppLocale): string {
  const key = `language.${code}` as MessageKey;
  return key in messages[locale] ? t(locale, key) : code;
}

export function useI18n() {
  const locale = useAppLocale();
  const translate = useCallback(
    (key: MessageKey, params?: MessageParams) => t(locale, key, params),
    [locale],
  );
  const getLanguageName = useCallback(
    (code: string) => languageName(code, locale),
    [locale],
  );
  return { locale, t: translate, languageName: getLanguageName };
}
