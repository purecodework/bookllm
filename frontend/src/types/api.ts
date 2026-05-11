export interface BookUsageStage {
  inputTokens: number;
  outputTokens: number;
}

export interface Book {
  id: string;
  title: string;
  sourceLang: string;
  targetLang: string;
  status: string;
  translationProgress: number;
  chapterId: string | null;
  coverUrl?: string | null;
  usageInputTokens?: number;
  usageOutputTokens?: number;
  usageByStage?: Record<string, BookUsageStage>;
  createdAt: string;
  updatedAt: string;
}

export interface Chapter {
  id: string;
  bookId: string;
  chapterNumber: number;
  title: string | null;
  status: string;
  translationProgress: number;
  translationStartedAt?: string | null;
  tokensPerSecond?: number | null;
  createdAt: string;
  updatedAt: string;
  pages?: Page[];
  _count?: { pages: number };
}

export interface Page {
  id: string;
  bookId: string;
  chapterId: string | null;
  pageNumber: number;
  sourceText: string | null;
  targetText: string | null;
  ocrStatus: string;
  translationStatus: string;
  retryCount: number;
  errorMessage?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ServiceHealth {
  status: "ok" | "error";
  latencyMs: number;
  message?: string;
  activeModel?: string;
  models?: string[];
  modelCount?: number;
  provider?: string;
}

export interface HealthReport {
  status: "ok" | "degraded" | "error";
  timestamp: string;
  services: {
    database: ServiceHealth;
    redis: ServiceHealth;
    ocr: ServiceHealth;
    llm: ServiceHealth;
  };
}

export interface LlmConfig {
  baseUrl: string;
  apiKey: string;
  apiKeyConfigured?: boolean;
  model: string;
  temperature: number;
  temperatureEnabled: boolean;
  timeoutMs: number;
}

export interface TranslationConfig {
  inputTokenBudget: number;
  contextWindowTokens: number;
  chunkSize?: number;
  concurrency: number;
  styleEnabled: boolean;
  stylePrompt: string;
  polishModelSource: "primary" | "sidekick";
  glossaryEnabled: boolean;
  glossaryModelSource: "primary" | "sidekick";
  reviewEnabled: boolean;
  reviewModelSource: "primary" | "sidekick";
}

export interface SidekickConfig {
  enabled: boolean;
  baseUrl: string;
  apiKey: string;
  apiKeyConfigured?: boolean;
  model: string;
  proofreadEnabled: boolean;
  polishEnabled: boolean;
}
