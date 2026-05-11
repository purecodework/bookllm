import { Body, Controller, Get, Put, Query } from '@nestjs/common';
import { SettingsService, maskApiKey, type LlmConfig, type LlmModelsResult, type SidekickConfig, type TranslationConfig } from './settings.service';

@Controller('settings')
export class SettingsController {
  constructor(private readonly settingsService: SettingsService) {}


  @Get('llm')
  async getLlm(): Promise<LlmConfig & { apiKeyConfigured: boolean }> {
    const cfg = await this.settingsService.getLlmConfig();
    return {
      ...cfg,
      apiKey: maskApiKey(cfg.apiKey),
      apiKeyConfigured: !!cfg.apiKey && cfg.apiKey !== 'local-dev-key',
    };
  }

  @Put('llm')
  saveLlm(@Body() body: Partial<LlmConfig>): Promise<void> {
    return this.settingsService.saveLlmConfig(body);
  }

  @Get('translation')
  getTranslation(): Promise<TranslationConfig> {
    return this.settingsService.getTranslationConfig();
  }

  @Put('translation')
  saveTranslation(@Body() body: Partial<TranslationConfig>): Promise<void> {
    return this.settingsService.saveTranslationConfig(body);
  }


  @Get('llm/models')
  async getModels(
    @Query('baseUrl') baseUrlQ?: string,
  ): Promise<LlmModelsResult> {
    const saved = await this.settingsService.getLlmConfig();
    const baseUrl = baseUrlQ ?? saved.baseUrl;
    return this.settingsService.fetchModels(baseUrl, saved.apiKey);
  }


  @Put('llm/models')
  async testModels(
    @Body() body: { baseUrl?: string; apiKey?: string },
  ): Promise<LlmModelsResult> {
    const saved = await this.settingsService.getLlmConfig();
    const baseUrl = body.baseUrl || saved.baseUrl;
    const apiKey  = body.apiKey  || saved.apiKey;
    return this.settingsService.fetchModels(baseUrl, apiKey);
  }


  @Put('sidekick/models')
  async testSidekickModels(
    @Body() body: { baseUrl?: string; apiKey?: string },
  ): Promise<LlmModelsResult> {
    const saved = await this.settingsService.getSidekickConfig();
    const baseUrl = body.baseUrl || saved.baseUrl;
    const apiKey = body.apiKey || saved.apiKey;
    return this.settingsService.fetchModels(baseUrl, apiKey);
  }

  @Get('sidekick')
  async getSidekick(): Promise<SidekickConfig & { apiKeyConfigured: boolean }> {
    const cfg = await this.settingsService.getSidekickConfig();
    return {
      ...cfg,
      apiKey: maskApiKey(cfg.apiKey),
      apiKeyConfigured: !!cfg.apiKey && cfg.apiKey !== 'local-dev-key',
    };
  }

  @Put('sidekick')
  saveSidekick(@Body() body: Partial<SidekickConfig>): Promise<void> {
    return this.settingsService.saveSidekickConfig(body);
  }
}
