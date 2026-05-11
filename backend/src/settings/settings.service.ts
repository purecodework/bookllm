import { BadGatewayException, Injectable, OnModuleInit } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom, timeout, catchError } from 'rxjs';
import { PrismaService } from '../prisma/prisma.service';

export interface LlmConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  temperature: number;
  temperatureEnabled: boolean;
  timeoutMs: number;
}

export interface TranslationConfig {
  inputTokenBudget: number;
  contextWindowTokens: number;
  concurrency: number;
  styleEnabled: boolean;
  stylePrompt: string;
  polishModelSource: 'primary' | 'sidekick';
  glossaryEnabled: boolean;
  glossaryModelSource: 'primary' | 'sidekick';
  reviewEnabled: boolean;
  reviewModelSource: 'primary' | 'sidekick';
  reasoningEffort: 'auto' | 'none';
}

export interface LlmModelsResult {
  models: string[];
  provider: string;
}

export interface SidekickConfig {
  enabled: boolean;
  baseUrl: string;
  apiKey: string;
  model: string;
  proofreadEnabled: boolean;
  polishEnabled: boolean;
  glossaryEnabled: boolean;
}

interface OpenAIModelDescriptor {
  id: string;
  owned_by?: string;
}

function normalizeUrl(url: string): string {
  if (process.env.RUNNING_IN_DOCKER !== 'true') return url;
  return url.replace(/\/\/(localhost)(:\d+)?/, '//host.docker.internal$2');
}

function parseNumber(raw: string | undefined, fallback: number): number {
  const num = Number(raw);
  return Number.isFinite(num) ? num : fallback;
}

function normalizeStylePrompt(raw: string | undefined): string {
  if (!raw) return '';
  return raw.trim().slice(0, 1000);
}

function redactSecrets(input: string): string {
  return input
    .replace(/\bsk-[A-Za-z0-9._-]{8,}\b/g, 'sk-***')
    .replace(/\b(Bearer\s+)[A-Za-z0-9._-]{8,}\b/gi, '$1***');
}

export function maskApiKey(key: string): string {
  if (!key || key === 'local-dev-key') return '';
  if (key.length <= 8) return '***';
  return `${key.slice(0, 4)}${'•'.repeat(8)}${key.slice(-4)}`;
}

export function isMaskedApiKey(value: string): boolean {
  return /^.{1,8}•{4,}.{1,8}$/.test(value) || value === '***';
}

const MIN_INPUT_TOKEN_BUDGET = 1024;
const DEFAULT_INPUT_TOKEN_BUDGET = 2000;
const MAX_INPUT_TOKEN_BUDGET = 20000;
const MIN_CONTEXT_WINDOW_TOKENS = 1024;
const DEFAULT_CONTEXT_WINDOW_TOKENS = 8192;
const MAX_CONTEXT_WINDOW_TOKENS = 1_000_000;
const MIN_TRANSLATION_CONCURRENCY = 1;
const MAX_TRANSLATION_CONCURRENCY = 32;

function clampInputTokenBudget(raw: number): number {
  if (!Number.isFinite(raw)) return MIN_INPUT_TOKEN_BUDGET;
  return Math.min(MAX_INPUT_TOKEN_BUDGET, Math.max(MIN_INPUT_TOKEN_BUDGET, Math.round(raw)));
}

function clampConcurrency(raw: number): number {
  if (!Number.isFinite(raw)) return MIN_TRANSLATION_CONCURRENCY;
  return Math.min(MAX_TRANSLATION_CONCURRENCY, Math.max(MIN_TRANSLATION_CONCURRENCY, Math.round(raw)));
}

function clampContextWindowTokens(raw: number): number {
  if (!Number.isFinite(raw)) return DEFAULT_CONTEXT_WINDOW_TOKENS;
  return Math.min(MAX_CONTEXT_WINDOW_TOKENS, Math.max(MIN_CONTEXT_WINDOW_TOKENS, Math.round(raw)));
}

function hostLabelFromBaseUrl(baseUrl: string): string | null {
  try {
    const host = new URL(baseUrl).hostname.toLowerCase();
    if (!host) return null;
    if (host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0' || host === 'host.docker.internal') {
      return null;
    }
    if (host.endsWith('openrouter.ai')) return 'openrouter';
    if (host.endsWith('openai.com')) return 'chatgpt';
    if (host.endsWith('x.ai')) return 'grok';
    if (host.includes('ollama')) return 'ollama';
    if (host.includes('lmstudio') || host.includes('lm-studio')) return 'lmstudio';
    if (host.includes('omlx')) return 'omlx';
    const parts = host.split('.');
    if (parts.length >= 2) return parts[parts.length - 2];
    return host;
  } catch {
    return null;
  }
}

function providerFromModels(models: string[]): string | null {
  const lowered = models.map((m) => m.toLowerCase());
  if (lowered.some((m) => /(^|\/)(gpt-|o[1-9]|chatgpt)/.test(m))) return 'chatgpt';
  if (lowered.some((m) => m.includes('grok'))) return 'grok';
  if (lowered.some((m) => m.includes('ollama'))) return 'ollama';
  if (lowered.some((m) => m.includes('lmstudio') || m.includes('lm-studio'))) return 'lmstudio';
  if (lowered.some((m) => m.includes('omlx'))) return 'omlx';
  return null;
}

function providerFromOwners(owners: string[]): string | null {
  const lowered = owners.map((o) => o.trim().toLowerCase()).filter(Boolean);
  if (lowered.length === 0) return null;
  if (lowered.includes('openai')) return 'chatgpt';
  if (lowered.includes('xai') || lowered.includes('x.ai')) return 'grok';
  if (lowered.includes('openrouter')) return 'openrouter';
  if (lowered.includes('ollama')) return 'ollama';
  if (lowered.includes('lmstudio') || lowered.includes('lm-studio')) return 'lmstudio';
  if (lowered.includes('omlx')) return 'omlx';
  return lowered[0];
}

@Injectable()
export class SettingsService implements OnModuleInit {
  constructor(
    private readonly prisma: PrismaService,
    private readonly httpService: HttpService,
  ) {}

  async onModuleInit(): Promise<void> {
    await this.runTokenBudgetMigration();
  }

  async getLlmConfig(): Promise<LlmConfig> {
    const rows = await this.prisma.settings.findMany({
      where: {
        key: {
          in: [
            'llm.baseUrl',
            'llm.apiKey',
            'llm.model',
            'llm.temperature',
            'llm.temperatureEnabled',
            'llm.timeoutMs',
          ],
        },
      },
    });
    const map = Object.fromEntries(rows.map((r) => [r.key, r.value]));
    const temperature = parseNumber(map['llm.temperature'] ?? process.env.OPENAI_TEMPERATURE, 0.2);
    const temperatureEnabled = map['llm.temperatureEnabled'] === 'true';
    const timeoutMs = parseNumber(map['llm.timeoutMs'] ?? process.env.OPENAI_TIMEOUT_MS, 60000);

    return {
      baseUrl: map['llm.baseUrl'] ?? process.env.OPENAI_BASE_URL ?? 'http://localhost:8000/v1',
      apiKey:  map['llm.apiKey']  ?? process.env.OPENAI_API_KEY  ?? 'local-dev-key',
      model:   map['llm.model']   ?? process.env.OPENAI_MODEL    ?? 'qwen2.5:7b',
      temperature: Math.min(2, Math.max(0, temperature)),
      temperatureEnabled,
      timeoutMs: Math.max(1000, timeoutMs),
    };
  }

  async getEffectiveLlmConfig(): Promise<LlmConfig> {
    const cfg = await this.getLlmConfig();
    return { ...cfg, baseUrl: normalizeUrl(cfg.baseUrl) };
  }

  async saveLlmConfig(config: Partial<LlmConfig>): Promise<void> {
    const entries: [string, string][] = [];
    if (config.baseUrl !== undefined) entries.push(['llm.baseUrl', config.baseUrl]);
    if (config.apiKey !== undefined && !isMaskedApiKey(config.apiKey) && config.apiKey !== '')
      entries.push(['llm.apiKey', config.apiKey]);
    if (config.model   !== undefined) entries.push(['llm.model',   config.model]);
    if (config.temperature !== undefined) entries.push(['llm.temperature', String(config.temperature)]);
    if (config.temperatureEnabled !== undefined) entries.push(['llm.temperatureEnabled', String(config.temperatureEnabled)]);
    if (config.timeoutMs !== undefined) entries.push(['llm.timeoutMs', String(config.timeoutMs)]);

    await Promise.all(
      entries.map(([key, value]) =>
        this.prisma.settings.upsert({
          where: { key },
          update: { value },
          create: { key, value },
        }),
      ),
    );
  }

  async getTranslationConfig(): Promise<TranslationConfig> {
    const rows = await this.prisma.settings.findMany({
      where: {
        key: {
          in: [
            'translation.inputTokenBudget',
            'translation.contextWindowTokens',
            'translation.chunkSize',
            'translation.concurrency',
            'translation.styleEnabled',
            'translation.stylePrompt',
            'translation.polishModelSource',
            'translation.glossaryEnabled',
            'translation.glossaryModelSource',
            'translation.reviewEnabled',
            'translation.reviewModelSource',
            'translation.reasoningEffort',
          ],
        },
      },
    });
    const map = Object.fromEntries(rows.map((r) => [r.key, r.value]));
    const rawEffort = map['translation.reasoningEffort'];
    return {
      inputTokenBudget: this.resolveInputTokenBudget(map),
      contextWindowTokens: clampContextWindowTokens(
        Number(map['translation.contextWindowTokens'] ?? process.env.TRANSLATION_CONTEXT_WINDOW_TOKENS ?? DEFAULT_CONTEXT_WINDOW_TOKENS),
      ),
      concurrency: clampConcurrency(Number(map['translation.concurrency'] ?? 1)),
      styleEnabled: map['translation.styleEnabled'] === 'true',
      stylePrompt: normalizeStylePrompt(
        map['translation.stylePrompt'] ?? process.env.TRANSLATION_STYLE_PROMPT ?? '',
      ),
      polishModelSource:
        map['translation.polishModelSource'] === 'sidekick' ? 'sidekick' : 'primary',
      glossaryEnabled: map['translation.glossaryEnabled'] === 'true',
      glossaryModelSource:
        map['translation.glossaryModelSource'] === 'sidekick' ? 'sidekick' : 'primary',
      reviewEnabled: map['translation.reviewEnabled'] === 'true',
      reviewModelSource:
        map['translation.reviewModelSource'] === 'sidekick' ? 'sidekick' : 'primary',
      reasoningEffort: rawEffort === 'auto' ? 'auto' : 'none',
    };
  }

  async saveTranslationConfig(config: Partial<TranslationConfig> & { chunkSize?: number }): Promise<void> {
    const entries: [string, string][] = [];
    const inputTokenBudgetRaw = config.inputTokenBudget ?? config.chunkSize;
    if (inputTokenBudgetRaw !== undefined) {
      const normalized = config.inputTokenBudget !== undefined
        ? clampInputTokenBudget(inputTokenBudgetRaw)
        : clampInputTokenBudget(Math.ceil(inputTokenBudgetRaw / 2));
      entries.push(['translation.inputTokenBudget', String(normalized)]);
    }
    if (config.concurrency !== undefined) {
      entries.push(['translation.concurrency', String(clampConcurrency(config.concurrency))]);
    }
    if (config.contextWindowTokens !== undefined) {
      entries.push([
        'translation.contextWindowTokens',
        String(clampContextWindowTokens(config.contextWindowTokens)),
      ]);
    }
    if (config.styleEnabled !== undefined) {
      entries.push(['translation.styleEnabled', String(config.styleEnabled)]);
    }
    if (config.stylePrompt !== undefined) {
      entries.push(['translation.stylePrompt', normalizeStylePrompt(config.stylePrompt)]);
    }
    if (config.polishModelSource !== undefined) {
      entries.push([
        'translation.polishModelSource',
        config.polishModelSource === 'sidekick' ? 'sidekick' : 'primary',
      ]);
    }
    if (config.glossaryEnabled !== undefined) {
      entries.push(['translation.glossaryEnabled', String(config.glossaryEnabled)]);
    }
    if (config.glossaryModelSource !== undefined) {
      entries.push([
        'translation.glossaryModelSource',
        config.glossaryModelSource === 'sidekick' ? 'sidekick' : 'primary',
      ]);
    }
    if (config.reviewEnabled !== undefined) {
      entries.push(['translation.reviewEnabled', String(config.reviewEnabled)]);
    }
    if (config.reviewModelSource !== undefined) {
      entries.push([
        'translation.reviewModelSource',
        config.reviewModelSource === 'sidekick' ? 'sidekick' : 'primary',
      ]);
    }
    if (config.reasoningEffort !== undefined) {
      entries.push(['translation.reasoningEffort', config.reasoningEffort === 'auto' ? 'auto' : 'none']);
    }
    await Promise.all(
      entries.map(([key, value]) =>
        this.prisma.settings.upsert({ where: { key }, update: { value }, create: { key, value } }),
      ),
    );
  }

  async getSidekickConfig(): Promise<SidekickConfig> {
    const rows = await this.prisma.settings.findMany({
      where: {
        key: {
          in: [
            'sidekick.enabled',
            'sidekick.baseUrl',
            'sidekick.apiKey',
            'sidekick.model',
            'sidekick.proofreadEnabled',
            'sidekick.polishEnabled',
            'sidekick.glossaryEnabled',
          ],
        },
      },
    });
    const map = Object.fromEntries(rows.map((r) => [r.key, r.value]));
    return {
      enabled: map['sidekick.enabled'] === 'true',
      baseUrl: map['sidekick.baseUrl'] ?? '',
      apiKey: map['sidekick.apiKey'] ?? '',
      model: map['sidekick.model'] ?? '',
      proofreadEnabled: map['sidekick.proofreadEnabled'] === 'true',
      polishEnabled: false,
      glossaryEnabled: map['sidekick.glossaryEnabled'] === 'true',
    };
  }

  async getEffectiveSidekickConfig(): Promise<SidekickConfig> {
    const cfg = await this.getSidekickConfig();
    return { ...cfg, baseUrl: normalizeUrl(cfg.baseUrl) };
  }

  async saveSidekickConfig(config: Partial<SidekickConfig>): Promise<void> {
    const entries: [string, string][] = [];
    if (config.enabled !== undefined) entries.push(['sidekick.enabled', String(config.enabled)]);
    if (config.baseUrl !== undefined) entries.push(['sidekick.baseUrl', config.baseUrl]);
    if (config.apiKey !== undefined && !isMaskedApiKey(config.apiKey) && config.apiKey !== '')
      entries.push(['sidekick.apiKey', config.apiKey]);
    if (config.model !== undefined) entries.push(['sidekick.model', config.model]);
    if (config.proofreadEnabled !== undefined) {
      entries.push(['sidekick.proofreadEnabled', String(config.proofreadEnabled)]);
    }
    entries.push(['sidekick.polishEnabled', 'false']);
    if (config.glossaryEnabled !== undefined)
      entries.push(['sidekick.glossaryEnabled', String(config.glossaryEnabled)]);
    await Promise.all(
      entries.map(([key, value]) =>
        this.prisma.settings.upsert({ where: { key }, update: { value }, create: { key, value } }),
      ),
    );
  }

  private resolveInputTokenBudget(map: Record<string, string>): number {
    const tokenRaw = Number(map['translation.inputTokenBudget']);
    if (Number.isFinite(tokenRaw)) {
      return clampInputTokenBudget(tokenRaw);
    }
    const legacyRaw = Number(map['translation.chunkSize'] ?? process.env.TRANSLATION_CHUNK_SIZE ?? '');
    if (Number.isFinite(legacyRaw) && legacyRaw > 0) {
      return clampInputTokenBudget(Math.ceil(legacyRaw / 2));
    }
    return clampInputTokenBudget(
      Number(process.env.TRANSLATION_INPUT_TOKEN_BUDGET ?? DEFAULT_INPUT_TOKEN_BUDGET),
    );
  }

  private async runTokenBudgetMigration(): Promise<void> {
    const rows = await this.prisma.settings.findMany({
      where: { key: { in: ['translation.inputTokenBudget', 'translation.chunkSize'] } },
    });
    const map = Object.fromEntries(rows.map((r) => [r.key, r.value]));
    if (map['translation.inputTokenBudget']) return;
    const budget = this.resolveInputTokenBudget(map);
    await this.prisma.settings.upsert({
      where: { key: 'translation.inputTokenBudget' },
      update: { value: String(budget) },
      create: { key: 'translation.inputTokenBudget', value: String(budget) },
    });
  }

  resolveProvider(baseUrl: string, models: string[]): string {
    return (
      providerFromModels(models) ??
      hostLabelFromBaseUrl(baseUrl) ??
      'unknown'
    );
  }

  async fetchModels(baseUrl: string, apiKey: string): Promise<LlmModelsResult> {
    const url = `${normalizeUrl(baseUrl).replace(/\/$/, '')}/models`;
    const res = await firstValueFrom(
      this.httpService
        .get<{ data?: OpenAIModelDescriptor[] }>(url, {
          headers: { Authorization: `Bearer ${apiKey}` },
        })
        .pipe(
          timeout(6000),
          catchError((err) => {
            const msg =
              (err?.response?.data?.error?.message as string | undefined) ??
              err?.message ??
              'Connection failed';
            throw new BadGatewayException({
              message: 'Failed to fetch models from OpenAI-compatible endpoint.',
              businessCode: 'LLM_MODELS_FETCH_FAILED',
              details: redactSecrets(msg),
            });
          }),
        ),
    );
    const modelItems = res.data?.data ?? [];
    const models = modelItems.map((m) => m.id);
    const owners = modelItems.map((m) => m.owned_by ?? '');
    const provider =
      providerFromOwners(owners) ??
      this.resolveProvider(baseUrl, models);
    return {
      models,
      provider,
    };
  }
}
