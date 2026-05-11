import { HttpModule, HttpService } from '@nestjs/axios';
import { Module } from '@nestjs/common';
import { SettingsService } from '../settings/settings.service';
import { LLM_SERVICE } from './llm.service';
import { OpenAICompatibleLlmService } from './openai-compatible-llm.service';

export function normalizeLlmProvider(provider?: string): 'ollama' | 'lmstudio' | 'omlx' | 'openai-compatible' {
  const value = (provider ?? '').trim().toLowerCase();
  if (value === 'ollama' || value === 'lmstudio' || value === 'omlx') return value;
  return 'openai-compatible';
}

@Module({
  imports: [HttpModule],
  providers: [
    OpenAICompatibleLlmService,
    {
      provide: LLM_SERVICE,
      useFactory: (httpService: HttpService, settingsService: SettingsService) =>
        new OpenAICompatibleLlmService(httpService, settingsService),
      inject: [HttpService, SettingsService],
    },
  ],
  exports: [LLM_SERVICE, OpenAICompatibleLlmService],
})
export class LlmModule {}
