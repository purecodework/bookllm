import { HttpService } from '@nestjs/axios';
import { BadGatewayException, Injectable } from '@nestjs/common';
import { firstValueFrom } from 'rxjs';
import { SettingsService } from '../settings/settings.service';
import { LlmService, TranslateOptions, TranslateResult } from './llm.service';

interface ChatCompletionResponse {
  choices?: Array<{ message?: { content?: string } }>;
  usage?: { completion_tokens?: number };
}

interface ChatCompletionChunk {
  choices?: Array<{ delta?: { content?: string } }>;
}

type RetryableError = {
  code?: string;
  response?: {
    status?: number;
  };
  message?: string;
};

interface ThinkingParams {

  extraBody: Record<string, unknown>;

  omitSystem: boolean;

  omitTemperature: boolean;
}

@Injectable()
export class OpenAICompatibleLlmService extends LlmService {
  constructor(
    private readonly httpService: HttpService,
    private readonly settingsService: SettingsService,
  ) {
    super();
  }


  resolveThinkingParams(model: string, reasoningEffort: 'auto' | 'none'): ThinkingParams {
    const none: ThinkingParams = { extraBody: {}, omitSystem: false, omitTemperature: false };
    const m = model.toLowerCase();


    if (/(?:^|\/)gpt-5(?:[.-]|$)/.test(m)) {
      return { extraBody: {}, omitSystem: false, omitTemperature: true };
    }

    if (reasoningEffort === 'none') return none;

    if (/(?:^|\/)o[1-9]\d*(?:[-/]|$)/.test(m) || /^o[1-9]\d*$/.test(m)) {
      return { extraBody: { reasoning_effort: 'medium' }, omitSystem: true, omitTemperature: true };
    }

    if (m.includes('deepseek') && (m.includes('r1') || m.includes('reason'))) {
      return { extraBody: { thinking: { type: 'enabled' } }, omitSystem: false, omitTemperature: false };
    }

    if (/qwen[3-9]/.test(m) || m.includes('qwq')) {
      return { extraBody: { enable_thinking: true }, omitSystem: false, omitTemperature: false };
    }

    if (m.includes('gemini')) {
      return { extraBody: { reasoning_effort: 'medium' }, omitSystem: false, omitTemperature: false };
    }

    return none;
  }

  private buildMessages(
    systemPrompt: string | undefined,
    userText: string,
    omitSystem: boolean,
  ): Array<{ role: string; content: string }> {
    const sys = systemPrompt ?? 'You are a translation assistant. Output only the translation, no explanations.';
    if (omitSystem) {
      return [{ role: 'user', content: `${sys}\n\n${userText}` }];
    }
    return [
      { role: 'system', content: sys },
      { role: 'user', content: userText },
    ];
  }

  private getRetryConfig() {
    return {
      maxRetries: Number(process.env.OPENAI_RETRY_MAX ?? 2),
      baseDelayMs: Number(process.env.OPENAI_RETRY_BASE_DELAY_MS ?? 800),
    };
  }

  private isRetryable(err: unknown): boolean {
    const e = err as RetryableError;
    const status = e?.response?.status;
    const code = e?.code ?? '';
    if (status !== undefined) {
      return [408, 409, 425, 429, 500, 502, 503, 504].includes(status);
    }
    return ['ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND', 'ECONNREFUSED'].includes(code);
  }

  private async sleep(ms: number): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, ms));
  }

  private parseStreamLine(line: string): string | null {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith(':')) return null;
    if (!trimmed.startsWith('data:')) return null;
    const payload = trimmed.slice('data:'.length).trim();
    return payload.length ? payload : null;
  }

  private tokenFromStreamPayload(payload: string): string | null {
    if (payload === '[DONE]') return null;
    try {
      return (JSON.parse(payload) as ChatCompletionChunk).choices?.[0]?.delta?.content ?? null;
    } catch {
      return null;
    }
  }

  async *translateStream(options: TranslateOptions): AsyncIterable<string> {
    const { baseUrl, apiKey, model, temperature, temperatureEnabled, timeoutMs } =
      await this.settingsService.getEffectiveLlmConfig();
    const { reasoningEffort } = await this.settingsService.getTranslationConfig();
    const { extraBody, omitSystem, omitTemperature } = this.resolveThinkingParams(model, reasoningEffort);
    const { maxRetries, baseDelayMs } = this.getRetryConfig();

    let response: { data: NodeJS.ReadableStream } | null = null;
    for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
      try {
        response = await this.httpService.axiosRef.post<NodeJS.ReadableStream>(
          `${baseUrl}/chat/completions`,
          {
            model,
            messages: this.buildMessages(options.systemPrompt, options.text, omitSystem),
            ...(omitTemperature || !temperatureEnabled ? {} : { temperature }),
            stream: true,
            ...extraBody,
          },
          {
            headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
            responseType: 'stream',
            timeout: timeoutMs,
          },
        );
        break;
      } catch (err) {
        if (attempt >= maxRetries || !this.isRetryable(err)) throw err;
        const waitMs = baseDelayMs * (2 ** attempt);
        await this.sleep(waitMs);
      }
    }

    if (!response) throw new Error('LLM stream response is empty');

    let buf = '';
    for await (const raw of response.data as AsyncIterable<Buffer>) {
      buf += raw.toString('utf8');
      const lines = buf.split('\n');
      buf = lines.pop() ?? '';
      for (const line of lines) {
        const payload = this.parseStreamLine(line);
        if (!payload) continue;
        if (payload === '[DONE]') return;
        const token = this.tokenFromStreamPayload(payload);
        if (token) yield token;
      }
    }
  }

  async translate(options: TranslateOptions): Promise<TranslateResult> {
    const { baseUrl, apiKey, model, temperature, temperatureEnabled, timeoutMs } =
      await this.settingsService.getEffectiveLlmConfig();
    const { reasoningEffort } = await this.settingsService.getTranslationConfig();
    const { extraBody, omitSystem, omitTemperature } = this.resolveThinkingParams(model, reasoningEffort);
    const { maxRetries, baseDelayMs } = this.getRetryConfig();
    const provider = this.settingsService.resolveProvider(
      baseUrl,
      [model].filter(Boolean),
    );
    const start = Date.now();

    let response: { data: ChatCompletionResponse } | null = null;
    for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
      try {
        response = await firstValueFrom(
          this.httpService.post<ChatCompletionResponse>(
            `${baseUrl}/chat/completions`,
            {
              model,
              messages: this.buildMessages(options.systemPrompt, options.text, omitSystem),
              ...(omitTemperature || !temperatureEnabled ? {} : { temperature }),
              ...extraBody,
            },
            {
              headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
              timeout: timeoutMs,
            },
          ),
        );
        break;
      } catch (err) {
        if (attempt >= maxRetries || !this.isRetryable(err)) throw err;
        const waitMs = baseDelayMs * (2 ** attempt);
        await this.sleep(waitMs);
      }
    }

    if (!response) throw new Error('LLM response is empty');

    const durationMs = Date.now() - start;
    const translated = response.data.choices?.[0]?.message?.content?.trim();
    if (!translated) {
      throw new BadGatewayException({
        message: 'LLM returned an empty translation.',
        businessCode: 'LLM_EMPTY_TRANSLATION',
      });
    }
    const tokenCount = response.data.usage?.completion_tokens;
    return {
      translatedText: translated,
      provider,
      model,
      tokenCount,
      durationMs,
    };
  }
}
