


import { getApiBase } from "@/lib/api-base";
import type {
  Book,
  Chapter,
  HealthReport,
  LlmConfig,
  Page,
  SidekickConfig,
  TranslationConfig,
} from "@/types/api";

export type {
  Book,
  Chapter,
  HealthReport,
  LlmConfig,
  Page,
  SidekickConfig,
  ServiceHealth,
  TranslationConfig,
} from "@/types/api";


const BASE_URL = () => getApiBase();

type ErrorPayload = {
  message?: unknown;
  details?: unknown;
  businessCode?: unknown;
  requestId?: unknown;
  error?: unknown;
};


async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL()}${path}`, {
    headers: { "Content-Type": "application/json", ...options?.headers },
    cache: "no-store",
    ...options,
  });
  if (!res.ok) {
    const err = (await res.json().catch(() => ({}))) as ErrorPayload;
    throw new Error(formatApiError(err, res.status));
  }
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

function toErrorText(value: unknown): string {
  if (Array.isArray(value)) return value.filter(Boolean).join("; ");
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const rec = value as Record<string, unknown>;
    if (typeof rec.message === "string") return rec.message;
    if (typeof rec.error === "string") return rec.error;
    try {
      return JSON.stringify(value);
    } catch {
      return "";
    }
  }
  return "";
}

function redactSecrets(input: string): string {
  return input
    .replace(/\bsk-[A-Za-z0-9._-]{8,}\b/g, "sk-***")
    .replace(/\b(Bearer\s+)[A-Za-z0-9._-]{8,}\b/gi, "$1***");
}

function humanizeBusinessCode(code: string): string {
  const normalized = code.trim().replace(/[_-]+/g, " ").toLowerCase();
  return normalized.replace(/\b\w/g, (ch) => ch.toUpperCase());
}

function formatApiError(payload: ErrorPayload, status: number): string {
  const details = toErrorText(payload.details).trim();
  const message = toErrorText(payload.message).trim();
  const businessCode =
    typeof payload.businessCode === "string" && payload.businessCode.trim()
      ? payload.businessCode.trim()
      : "";
  const requestId =
    typeof payload.requestId === "string" && payload.requestId.trim()
      ? payload.requestId.trim()
      : "";

  const readable =
    details ||
    message ||
    (businessCode ? humanizeBusinessCode(businessCode) : "") ||
    `HTTP ${status}`;
  const parts = [readable];
  if (businessCode) parts.push(`[${businessCode}]`);
  if (requestId) parts.push(`(Request: ${requestId})`);
  return redactSecrets(parts.join(" "));
}


export async function fetchHealth(): Promise<HealthReport | null> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    const res = await fetch(`${BASE_URL()}/health`, {
      signal: controller.signal,
      cache: "no-store",
    });
    clearTimeout(timer);
    if (!res.ok) return null;
    return res.json() as Promise<HealthReport>;
  } catch {
    return null;
  }
}

export function providerLabel(provider?: string): string {
  const map: Record<string, string> = {
    omlx: "OMLX",
    ollama: "Ollama",
    lmstudio: "LM Studio",
    openai: "OpenAI",
    chatgpt: "ChatGPT",
    grok: "Grok",
    openrouter: "OpenRouter",
    unknown: "Unknown",
  };
  if (!provider) return "";
  const normalized = provider.trim().toLowerCase();
  if (map[normalized]) return map[normalized];
  return provider
    .replace(/[-_]+/g, " ")
    .replace(/\b\w/g, (ch) => ch.toUpperCase());
}


export function fetchBooks(): Promise<Book[]> {
  return request<Book[]>("/books");
}

export function fetchBook(id: string): Promise<Book> {
  return request<Book>(`/books/${id}`);
}

export function createBook(dto: {
  title: string;
  sourceLang: string;
  targetLang: string;
}): Promise<Book> {
  return request<Book>("/books", {
    method: "POST",
    body: JSON.stringify(dto),
  });
}

export function deleteBook(id: string): Promise<void> {
  return request<void>(`/books/${id}`, { method: "DELETE" });
}


export function fetchChaptersByBook(bookId: string): Promise<Chapter[]> {
  return request<Chapter[]>(`/chapters/book/${bookId}`);
}

export function createChapter(dto: {
  bookId: string;
  chapterNumber: number;
  title?: string;
}): Promise<Chapter> {
  return request<Chapter>("/chapters", {
    method: "POST",
    body: JSON.stringify(dto),
  });
}

export function startBookTranslation(
  bookId: string,
): Promise<{ enqueuedPages: number }> {
  return request<{ enqueuedPages: number }>(
    `/chapters/book/${bookId}/translate`,
    { method: "POST" },
  );
}

export function pauseTranslation(
  chapterId: string,
): Promise<{ paused: boolean }> {
  return request<{ paused: boolean }>(
    `/chapters/${chapterId}/pause-translation`,
    { method: "POST" },
  );
}

export function resumeTranslation(
  chapterId: string,
): Promise<{ paused: boolean }> {
  return request<{ paused: boolean }>(
    `/chapters/${chapterId}/resume-translation`,
    { method: "POST" },
  );
}


export function fetchPagesByChapter(chapterId: string): Promise<Page[]> {
  return request<Page[]>(`/pages/chapter/${chapterId}`);
}


export async function uploadPdf(
  file: File,
  bookId: string,
  chapterId: string,
  language: string,
  ocrMode: "auto" | "force" = "auto",
): Promise<Page[]> {
  const form = new FormData();
  form.append("file", file);
  form.append("bookId", bookId);
  form.append("chapterId", chapterId);
  form.append("language", language);
  form.append("ocrMode", ocrMode);

  const res = await fetch(`${BASE_URL()}/pages/upload/pdf`, {
    method: "POST",
    body: form,

  });

  if (!res.ok) {
    const err = (await res.json().catch(() => ({}))) as ErrorPayload;
    throw new Error(formatApiError(err, res.status));
  }
  return res.json() as Promise<Page[]>;
}

export async function uploadTxt(
  file: File,
  bookId: string,
  chapterId: string,
): Promise<Page[]> {
  const form = new FormData();
  form.append("file", file);
  form.append("bookId", bookId);
  form.append("chapterId", chapterId);
  const res = await fetch(`${BASE_URL()}/pages/upload/txt`, {
    method: "POST",
    body: form,
  });
  if (!res.ok) {
    const err = (await res.json().catch(() => ({}))) as ErrorPayload;
    throw new Error(formatApiError(err, res.status));
  }
  return res.json() as Promise<Page[]>;
}

export async function uploadEpub(
  file: File,
  bookId: string,
  chapterId: string,
): Promise<Page[]> {
  const form = new FormData();
  form.append("file", file);
  form.append("bookId", bookId);
  form.append("chapterId", chapterId);
  const res = await fetch(`${BASE_URL()}/pages/upload/epub`, {
    method: "POST",
    body: form,
  });
  if (!res.ok) {
    const err = (await res.json().catch(() => ({}))) as ErrorPayload;
    throw new Error(formatApiError(err, res.status));
  }
  return res.json() as Promise<Page[]>;
}


export function getLlmConfig(): Promise<LlmConfig> {
  return request<LlmConfig>("/settings/llm");
}

export function saveLlmConfig(config: Partial<LlmConfig>): Promise<void> {
  return request<void>("/settings/llm", {
    method: "PUT",
    body: JSON.stringify(config),
  });
}

export function getTranslationConfig(): Promise<TranslationConfig> {
  return request<TranslationConfig>("/settings/translation");
}

export function saveTranslationConfig(
  config: Partial<TranslationConfig>,
): Promise<void> {
  return request<void>("/settings/translation", {
    method: "PUT",
    body: JSON.stringify(config),
  });
}

export function getSidekickConfig(): Promise<SidekickConfig> {
  return request<SidekickConfig>("/settings/sidekick");
}

export function saveSidekickConfig(
  config: Partial<SidekickConfig>,
): Promise<void> {
  return request<void>("/settings/sidekick", {
    method: "PUT",
    body: JSON.stringify(config),
  });
}

export async function testLlmConnection(
  baseUrl: string,
  apiKey: string,
): Promise<{ models: string[]; provider: string }> {
  const res = await request<{ models: string[]; provider?: string }>(
    "/settings/llm/models",
    { method: "PUT", body: JSON.stringify({ baseUrl, apiKey }) },
  );
  return {
    models: res.models ?? [],
    provider: res.provider ?? "unknown",
  };
}

export async function testSidekickConnection(
  baseUrl: string,
  apiKey: string,
): Promise<{ models: string[]; provider: string }> {
  const res = await request<{ models: string[]; provider?: string }>(
    "/settings/sidekick/models",
    { method: "PUT", body: JSON.stringify({ baseUrl, apiKey }) },
  );
  return {
    models: res.models ?? [],
    provider: res.provider ?? "unknown",
  };
}
