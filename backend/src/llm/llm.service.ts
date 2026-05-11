export const LLM_SERVICE = Symbol('LLM_SERVICE');

export interface TranslateOptions {
  text: string;
  targetLang: string;

  systemPrompt?: string;
}

export interface TranslateResult {
  translatedText: string;
  provider: string;
  model: string;

  tokenCount?: number;

  durationMs?: number;
}


export abstract class LlmService {
  abstract translate(options: TranslateOptions): Promise<TranslateResult>;
  abstract translateStream(options: TranslateOptions): AsyncIterable<string>;
}
