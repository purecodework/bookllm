import { of } from 'rxjs';
import { SettingsService } from './settings.service';

describe('SettingsService provider resolution', () => {
  const service = new SettingsService({} as never, {} as never);

  it('prefers model signal (gpt -> chatgpt)', () => {
    const provider = service.resolveProvider('https://openrouter.ai/api/v1', ['gpt-4.1']);
    expect(provider).toBe('chatgpt');
  });

  it('detects grok from models', () => {
    const provider = service.resolveProvider('https://example.com/v1', ['grok-4']);
    expect(provider).toBe('grok');
  });

  it('falls back to host label when models do not reveal provider', () => {
    const provider = service.resolveProvider('https://openrouter.ai/v1', ['meta-llama/llama-3.1']);
    expect(provider).toBe('openrouter');
  });

  it('returns unknown as final fallback', () => {
    const provider = service.resolveProvider('not-a-valid-url', []);
    expect(provider).toBe('unknown');
  });
});

describe('SettingsService.fetchModels', () => {
  it('prefers provider from owned_by when available', async () => {
    const httpService = {
      get: jest.fn().mockReturnValue(
        of({
          data: {
            data: [
              { id: 'qwen-heretic', owned_by: 'omlx' },
              { id: 'gemma4-26b', owned_by: 'omlx' },
            ],
          },
        }),
      ),
    };
    const service = new SettingsService({} as never, httpService as never);

    const result = await service.fetchModels('http://localhost:8008/v1', '1234');

    expect(result.models).toEqual(['qwen-heretic', 'gemma4-26b']);
    expect(result.provider).toBe('omlx');
  });

  it('returns models and inferred provider', async () => {
    const httpService = {
      get: jest.fn().mockReturnValue(
        of({ data: { data: [{ id: 'gpt-4.1-mini' }, { id: 'o4-mini' }] } }),
      ),
    };
    const service = new SettingsService({} as never, httpService as never);

    const result = await service.fetchModels('https://api.openai.com/v1', 'sk-test');

    expect(httpService.get).toHaveBeenCalledWith(
      'https://api.openai.com/v1/models',
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: 'Bearer sk-test',
        }),
      }),
    );
    expect(result.models).toEqual(['gpt-4.1-mini', 'o4-mini']);
    expect(result.provider).toBe('chatgpt');
  });
});

describe('SettingsService translation config', () => {
  it('migrates legacy chunkSize chars to inputTokenBudget tokens (2400 -> 1200) on startup', async () => {

    const findMany = jest.fn().mockResolvedValue([
      { key: 'translation.chunkSize', value: '2400' },
    ]);
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { findMany, upsert } };
    const service = new SettingsService(prisma as never, {} as never);


    await service.onModuleInit();

    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({
          key: 'translation.inputTokenBudget',
          value: '1200',
        }),
      }),
    );
  });

  it('getTranslationConfig computes inputTokenBudget from legacy chunkSize when no inputTokenBudget stored', async () => {
    const findMany = jest.fn().mockResolvedValue([
      { key: 'translation.chunkSize', value: '2400' },
    ]);
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { findMany, upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    const cfg = await service.getTranslationConfig();
    expect(cfg.inputTokenBudget).toBe(1200);
    expect(cfg.contextWindowTokens).toBe(8192);

    expect(upsert).not.toHaveBeenCalled();
  });

  it('clamps inputTokenBudget to 1024 on save', async () => {
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    await service.saveTranslationConfig({ inputTokenBudget: 256, concurrency: 1 });

    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({ key: 'translation.inputTokenBudget', value: '1024' }),
      }),
    );
  });

  it('clamps contextWindowTokens to 1024 on save', async () => {
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    await service.saveTranslationConfig({ contextWindowTokens: 128 });

    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({ key: 'translation.contextWindowTokens', value: '1024' }),
      }),
    );
  });

  it('uses default inputTokenBudget when nothing is stored', async () => {
    const findMany = jest.fn().mockResolvedValue([]);
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { findMany, upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    const cfg = await service.getTranslationConfig();
    expect(cfg.inputTokenBudget).toBeGreaterThanOrEqual(1024);
    expect(cfg.contextWindowTokens).toBe(8192);
    expect(cfg.styleEnabled).toBe(false);
    expect(cfg.stylePrompt).toBe('');
    expect(cfg.polishModelSource).toBe('primary');
    expect(cfg.glossaryEnabled).toBe(false);
    expect(cfg.glossaryModelSource).toBe('primary');
    expect(cfg.reviewEnabled).toBe(false);
    expect(cfg.reviewModelSource).toBe('primary');
  });

  it('clamps concurrency to 32 on save', async () => {
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    await service.saveTranslationConfig({ concurrency: 99 });

    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({ key: 'translation.concurrency', value: '32' }),
      }),
    );
  });

  it('clamps concurrency to 32 on read', async () => {
    const findMany = jest.fn().mockResolvedValue([
      { key: 'translation.concurrency', value: '42' },
      { key: 'translation.inputTokenBudget', value: '1200' },
    ]);
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { findMany, upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    const cfg = await service.getTranslationConfig();
    expect(cfg.concurrency).toBe(32);
  });

  it('reads stored contextWindowTokens', async () => {
    const findMany = jest.fn().mockResolvedValue([
      { key: 'translation.concurrency', value: '1' },
      { key: 'translation.inputTokenBudget', value: '1200' },
      { key: 'translation.contextWindowTokens', value: '32768' },
    ]);
    const upsert = jest.fn().mockResolvedValue({});
    const prisma = { settings: { findMany, upsert } };
    const service = new SettingsService(prisma as never, {} as never);

    const cfg = await service.getTranslationConfig();
    expect(cfg.contextWindowTokens).toBe(32768);
  });
});

describe('SettingsService sidekick config', () => {
  const oldDockerFlag = process.env.RUNNING_IN_DOCKER;

  afterEach(() => {
    process.env.RUNNING_IN_DOCKER = oldDockerFlag;
  });

  it('normalizes localhost sidekick baseUrl when running in Docker', async () => {
    process.env.RUNNING_IN_DOCKER = 'true';
    const findMany = jest.fn().mockResolvedValue([
      { key: 'sidekick.enabled', value: 'true' },
      { key: 'sidekick.baseUrl', value: 'http://localhost:19001/v1' },
      { key: 'sidekick.apiKey', value: 'sk-test' },
      { key: 'sidekick.model', value: 'gpt-4.1-mini' },
      { key: 'sidekick.proofreadEnabled', value: 'true' },
      { key: 'sidekick.polishEnabled', value: 'false' },
      { key: 'sidekick.glossaryEnabled', value: 'true' },
    ]);
    const service = new SettingsService({ settings: { findMany } } as never, {} as never);

    const cfg = await service.getEffectiveSidekickConfig();

    expect(cfg.baseUrl).toBe('http://host.docker.internal:19001/v1');
  });

  it('defaults reviewer features to disabled for first-time users', async () => {
    const findMany = jest.fn().mockResolvedValue([]);
    const service = new SettingsService({ settings: { findMany } } as never, {} as never);

    const cfg = await service.getSidekickConfig();

    expect(cfg.enabled).toBe(false);
    expect(cfg.proofreadEnabled).toBe(false);
    expect(cfg.polishEnabled).toBe(false);
    expect(cfg.glossaryEnabled).toBe(false);
    expect(cfg.baseUrl).toBe('');
    expect(cfg.model).toBe('');
  });

  it('persists sidekick connection and review flags independently, keeps polish disabled', async () => {
    const upsert = jest.fn().mockResolvedValue({});
    const service = new SettingsService({ settings: { upsert } } as never, {} as never);

    await service.saveSidekickConfig({
      enabled: false,
      baseUrl: 'https://api.openai.com/v1',
      apiKey: '',
      model: 'gpt-4o-mini',
      proofreadEnabled: false,
      polishEnabled: true,
    });

    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { key: 'sidekick.enabled' },
        update: { value: 'false' },
        create: { key: 'sidekick.enabled', value: 'false' },
      }),
    );
    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { key: 'sidekick.proofreadEnabled' },
        update: { value: 'false' },
        create: { key: 'sidekick.proofreadEnabled', value: 'false' },
      }),
    );
    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { key: 'sidekick.polishEnabled' },
        update: { value: 'false' },
        create: { key: 'sidekick.polishEnabled', value: 'false' },
      }),
    );
  });

  it('reads sidekick proofread flag independently from connection enabled', async () => {
    const findMany = jest.fn().mockResolvedValue([
      { key: 'sidekick.enabled', value: 'false' },
      { key: 'sidekick.proofreadEnabled', value: 'true' },
      { key: 'sidekick.baseUrl', value: '' },
      { key: 'sidekick.model', value: '' },
    ]);
    const service = new SettingsService({ settings: { findMany } } as never, {} as never);
    const cfg = await service.getSidekickConfig();
    expect(cfg.enabled).toBe(false);
    expect(cfg.proofreadEnabled).toBe(true);
  });
});
