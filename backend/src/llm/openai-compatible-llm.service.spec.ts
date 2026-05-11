import { type HttpService } from '@nestjs/axios';
import { of, throwError } from 'rxjs';
import { Readable } from 'stream';
import { OpenAICompatibleLlmService } from './openai-compatible-llm.service';
import { type SettingsService } from '../settings/settings.service';

function makeSettingsMock(
  overrides: Partial<{
    baseUrl: string;
    apiKey: string;
    model: string;
    temperature: number;
    temperatureEnabled: boolean;
    timeoutMs: number;
    reasoningEffort: 'auto' | 'none';
  }> = {},
) {
  const { reasoningEffort = 'none', ...llmOverrides } = overrides;
  return {
    getEffectiveLlmConfig: jest.fn().mockResolvedValue({
      baseUrl: 'http://127.0.0.1:11434/v1',
      apiKey: 'local-dev-key',
      model: 'qwen2.5:7b',
      temperature: 0.2,
      temperatureEnabled: true,
      timeoutMs: 60000,
      ...llmOverrides,
    }),
    getTranslationConfig: jest.fn().mockResolvedValue({ reasoningEffort }),
    resolveProvider: jest.fn().mockReturnValue('ollama'),
  };
}

function makeSleepSpy(service: OpenAICompatibleLlmService) {
  return jest
    .spyOn(service as unknown as { sleep: (ms: number) => Promise<void> }, 'sleep')
    .mockResolvedValue(undefined);
}


describe('OpenAICompatibleLlmService.translate()', () => {
  let service: OpenAICompatibleLlmService;
  let httpService: { post: jest.Mock; axiosRef: { post: jest.Mock } };
  let settings: ReturnType<typeof makeSettingsMock>;

  beforeEach(() => {
    httpService = { post: jest.fn(), axiosRef: { post: jest.fn() } };
    settings = makeSettingsMock();
    service = new OpenAICompatibleLlmService(
      httpService as unknown as HttpService,
      settings as unknown as SettingsService,
    );
  });

  it('calls the OpenAI-compatible endpoint and returns translated text', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'hello world' } }] } }),
    );

    const result = await service.translate({ text: '你好世界', targetLang: 'en' });

    expect(httpService.post).toHaveBeenCalledTimes(1);
    expect(httpService.post.mock.calls[0][0]).toBe('http://127.0.0.1:11434/v1/chat/completions');
    expect(httpService.post.mock.calls[0][1]).toMatchObject({
      model: 'qwen2.5:7b',
      temperature: 0.2,
    });
    expect(httpService.post.mock.calls[0][1]).not.toHaveProperty('top_p');
    expect(httpService.post.mock.calls[0][2]).toMatchObject({ timeout: 60000 });
    expect(result.translatedText).toBe('hello world');
    expect(settings.resolveProvider).toHaveBeenCalledWith('http://127.0.0.1:11434/v1', ['qwen2.5:7b']);
    expect(result.provider).toBe('ollama');
    expect(result.model).toBe('qwen2.5:7b');
  });

  it('sends a custom system prompt when provided', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'hi' } }] } }),
    );

    await service.translate({ text: 'hello', targetLang: 'zh', systemPrompt: 'custom-system-prompt' });

    const messages = httpService.post.mock.calls[0][1].messages as Array<{ role: string; content: string }>;
    const sysMsg = messages.find((m) => m.role === 'system');
    expect(sysMsg?.content).toBe('custom-system-prompt');
  });

  it('handles official OpenAI chat/completions endpoint', async () => {
    settings = makeSettingsMock({ baseUrl: 'https://api.openai.com/v1', model: 'gpt-4.1-mini' });
    settings.resolveProvider.mockReturnValue('chatgpt');
    service = new OpenAICompatibleLlmService(
      httpService as unknown as HttpService,
      settings as unknown as SettingsService,
    );
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'Hello world' } }] } }),
    );

    const result = await service.translate({ text: '你好，世界', targetLang: 'en' });

    expect(httpService.post).toHaveBeenCalledWith(
      'https://api.openai.com/v1/chat/completions',
      expect.objectContaining({ model: 'gpt-4.1-mini' }),
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: expect.stringMatching(/^Bearer /) }),
      }),
    );
    expect(result.translatedText).toBe('Hello world');
    expect(result.provider).toBe('chatgpt');
    expect(result.model).toBe('gpt-4.1-mini');
  });

  it('throws LLM_EMPTY_TRANSLATION when choices is empty', async () => {
    httpService.post.mockReturnValue(of({ data: { choices: [] } }));

    await expect(service.translate({ text: '测试', targetLang: 'en' })).rejects.toMatchObject({
      response: expect.objectContaining({ businessCode: 'LLM_EMPTY_TRANSLATION' }),
    });
  });

  it('throws LLM_EMPTY_TRANSLATION when content is an empty string', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: '' } }] } }),
    );

    await expect(service.translate({ text: 'text', targetLang: 'en' })).rejects.toMatchObject({
      response: expect.objectContaining({ businessCode: 'LLM_EMPTY_TRANSLATION' }),
    });
  });

  it('throws LLM_EMPTY_TRANSLATION when content is whitespace only', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: '   \n  ' } }] } }),
    );

    await expect(service.translate({ text: 'text', targetLang: 'en' })).rejects.toMatchObject({
      response: expect.objectContaining({ businessCode: 'LLM_EMPTY_TRANSLATION' }),
    });
  });

  it('returns usage.completion_tokens as tokenCount', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'hello' } }], usage: { completion_tokens: 42 } } }),
    );

    const result = await service.translate({ text: '你好', targetLang: 'en' });
    expect(result.tokenCount).toBe(42);
  });

  it('returns undefined tokenCount when usage is absent', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'hello' } }] } }),
    );

    const result = await service.translate({ text: '你好', targetLang: 'en' });
    expect(result.tokenCount).toBeUndefined();
  });

  it('durationMs is a non-negative number', async () => {
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'hi' } }] } }),
    );

    const result = await service.translate({ text: 'test', targetLang: 'en' });
    expect(typeof result.durationMs).toBe('number');
    expect(result.durationMs).toBeGreaterThanOrEqual(0);
  });

  describe('retry logic', () => {
    it('retries on 429 and eventually succeeds', async () => {
      const sleepSpy = makeSleepSpy(service);
      httpService.post
        .mockReturnValueOnce(throwError(() => ({ response: { status: 429 } })))
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: 'retry ok' } }] } }));

      const result = await service.translate({ text: '你好', targetLang: 'en' });

      expect(httpService.post).toHaveBeenCalledTimes(2);
      expect(sleepSpy).toHaveBeenCalledTimes(1);
      expect(result.translatedText).toBe('retry ok');
    });

    it.each([408, 409, 425, 500, 502, 503, 504])('retries on HTTP %i', async (status) => {
      const sleepSpy = makeSleepSpy(service);
      httpService.post
        .mockReturnValueOnce(throwError(() => ({ response: { status } })))
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: 'ok' } }] } }));

      const result = await service.translate({ text: 'x', targetLang: 'en' });
      expect(sleepSpy).toHaveBeenCalledTimes(1);
      expect(result.translatedText).toBe('ok');
    });

    it('does NOT retry on HTTP 400 (client error)', async () => {
      const sleepSpy = makeSleepSpy(service);
      httpService.post.mockReturnValue(throwError(() => ({ response: { status: 400 } })));

      await expect(service.translate({ text: 'x', targetLang: 'en' })).rejects.toMatchObject({
        response: { status: 400 },
      });
      expect(httpService.post).toHaveBeenCalledTimes(1);
      expect(sleepSpy).not.toHaveBeenCalled();
    });

    it.each(['ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND', 'ECONNREFUSED'])(
      'retries on network error %s',
      async (code) => {
        const sleepSpy = makeSleepSpy(service);
        httpService.post
          .mockReturnValueOnce(throwError(() => ({ code })))
          .mockReturnValueOnce(of({ data: { choices: [{ message: { content: 'ok' } }] } }));

        const result = await service.translate({ text: 'x', targetLang: 'en' });
        expect(sleepSpy).toHaveBeenCalledTimes(1);
        expect(result.translatedText).toBe('ok');
      },
    );

    it('exhausts retries and throws the final error', async () => {
      const sleepSpy = makeSleepSpy(service);
      const err = { response: { status: 503 } };

      httpService.post.mockReturnValue(throwError(() => err));

      await expect(service.translate({ text: 'x', targetLang: 'en' })).rejects.toMatchObject(err);
      expect(httpService.post).toHaveBeenCalledTimes(3);
      expect(sleepSpy).toHaveBeenCalledTimes(2);
    });

    it('uses exponential backoff: second retry waits twice as long as the first', async () => {
      const sleepSpy = makeSleepSpy(service);
      httpService.post.mockReturnValue(throwError(() => ({ response: { status: 503 } })));

      await expect(service.translate({ text: 'x', targetLang: 'en' })).rejects.toBeDefined();

      const [firstWait, secondWait] = sleepSpy.mock.calls.map((c) => c[0] as number);
      expect(secondWait).toBe(firstWait * 2);
    });
  });
});


describe('OpenAICompatibleLlmService.translateStream()', () => {
  let service: OpenAICompatibleLlmService;
  let httpService: { post: jest.Mock; axiosRef: { post: jest.Mock } };

  beforeEach(() => {
    httpService = { post: jest.fn(), axiosRef: { post: jest.fn() } };
    service = new OpenAICompatibleLlmService(
      httpService as unknown as HttpService,
      makeSettingsMock() as unknown as SettingsService,
    );
  });

  async function collect(gen: AsyncIterable<string>): Promise<string[]> {
    const out: string[] = [];
    for await (const t of gen) out.push(t);
    return out;
  }

  it('parses standard OpenAI SSE chunks and yields content tokens', async () => {
    httpService.axiosRef.post.mockResolvedValue({
      data: Readable.from([
        ': keep-alive\n\n',
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"你"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"好"}}]}\n\n',
        'data: [DONE]\n\n',
      ]),
    });

    const tokens = await collect(service.translateStream({ text: 'hello', targetLang: 'zh' }));
    expect(tokens.join('')).toBe('你好');
  });

  it('accepts data lines without a space after the colon', async () => {
    httpService.axiosRef.post.mockResolvedValue({
      data: Readable.from([
        'data:{"choices":[{"delta":{"content":"A"}}]}\n',
        'data:{"choices":[{"delta":{"content":"B"}}]}\n',
        'data:[DONE]\n',
      ]),
    });

    const tokens = await collect(service.translateStream({ text: 'ab', targetLang: 'zh' }));
    expect(tokens.join('')).toBe('AB');
  });

  it('stops at [DONE] and does not yield further tokens', async () => {
    httpService.axiosRef.post.mockResolvedValue({
      data: Readable.from([
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n',
        'data: [DONE]\n',
        'data: {"choices":[{"delta":{"content":"NEVER"}}]}\n',
      ]),
    });

    const tokens = await collect(service.translateStream({ text: 'x', targetLang: 'zh' }));
    expect(tokens).toEqual(['ok']);
  });

  it('skips chunks where delta.content is absent (role-only messages)', async () => {
    httpService.axiosRef.post.mockResolvedValue({
      data: Readable.from([
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n',
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n',
        'data: [DONE]\n',
      ]),
    });

    const tokens = await collect(service.translateStream({ text: 'x', targetLang: 'zh' }));
    expect(tokens).toEqual(['hi']);
  });

  it('skips malformed JSON lines without throwing', async () => {
    httpService.axiosRef.post.mockResolvedValue({
      data: Readable.from([
        'data: {broken json\n',
        'data: {"choices":[{"delta":{"content":"safe"}}]}\n',
        'data: [DONE]\n',
      ]),
    });

    const tokens = await collect(service.translateStream({ text: 'x', targetLang: 'zh' }));
    expect(tokens).toEqual(['safe']);
  });

  it('handles SSE data split across buffer boundaries', async () => {
    httpService.axiosRef.post.mockResolvedValue({
      data: Readable.from([
        Buffer.from('data: {"choices":[{"delta":{"cont'),
        Buffer.from('ent":"X"}}]}\ndata: [DONE]\n'),
      ]),
    });

    const tokens = await collect(service.translateStream({ text: 'x', targetLang: 'zh' }));
    expect(tokens).toEqual(['X']);
  });

  it('retries on 429 and succeeds on the second attempt', async () => {
    const sleepSpy = makeSleepSpy(service);
    httpService.axiosRef.post
      .mockRejectedValueOnce({ response: { status: 429 } })
      .mockResolvedValueOnce({
        data: Readable.from([
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n',
          'data: [DONE]\n',
        ]),
      });

    const tokens = await collect(service.translateStream({ text: 'x', targetLang: 'zh' }));
    expect(tokens).toEqual(['ok']);
    expect(sleepSpy).toHaveBeenCalledTimes(1);
  });

  it('throws after exhausting stream retries', async () => {
    makeSleepSpy(service);
    const err = { response: { status: 503 } };
    httpService.axiosRef.post.mockRejectedValue(err);

    await expect(
      collect(service.translateStream({ text: 'x', targetLang: 'zh' })),
    ).rejects.toMatchObject(err);
    expect(httpService.axiosRef.post).toHaveBeenCalledTimes(3);
  });

  it('uses Bearer token in Authorization header', async () => {
    httpService.axiosRef.post.mockResolvedValue({ data: Readable.from(['data: [DONE]\n']) });

    await collect(service.translateStream({ text: 'x', targetLang: 'zh' }));

    const headers = httpService.axiosRef.post.mock.calls[0][2].headers as Record<string, string>;
    expect(headers['Authorization']).toMatch(/^Bearer /);
  });
});


describe('OpenAICompatibleLlmService.isRetryable (private)', () => {
  const service = new OpenAICompatibleLlmService(
    {} as unknown as HttpService,
    {} as unknown as SettingsService,
  );
  const isRetryable = (err: unknown) =>
    (service as unknown as { isRetryable: (e: unknown) => boolean }).isRetryable(err);

  it.each([408, 409, 425, 429, 500, 502, 503, 504])(
    'returns true for HTTP status %i',
    (status) => expect(isRetryable({ response: { status } })).toBe(true),
  );

  it.each([400, 401, 403, 404, 422])(
    'returns false for non-retryable HTTP status %i',
    (status) => expect(isRetryable({ response: { status } })).toBe(false),
  );

  it.each(['ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND', 'ECONNREFUSED'])(
    'returns true for network error code %s',
    (code) => expect(isRetryable({ code })).toBe(true),
  );

  it('returns false for unknown error code', () => {
    expect(isRetryable({ code: 'EUNKNOWN' })).toBe(false);
  });

  it('prefers HTTP status over error code when both are present', () => {
    expect(isRetryable({ response: { status: 400 }, code: 'ECONNRESET' })).toBe(false);
    expect(isRetryable({ response: { status: 429 }, code: 'EUNKNOWN' })).toBe(true);
  });
});


describe('OpenAICompatibleLlmService.resolveThinkingParams()', () => {
  const service = new OpenAICompatibleLlmService(
    {} as unknown as HttpService,
    {} as unknown as SettingsService,
  );
  const resolve = (model: string, effort: 'auto' | 'none') =>
    service.resolveThinkingParams(model, effort);

  it('returns empty params when reasoningEffort is none', () => {
    expect(resolve('deepseek-r1', 'none')).toEqual({ extraBody: {}, omitSystem: false, omitTemperature: false });
  });

  it.each(['o1', 'o3', 'o4-mini', 'o1-preview', 'openai/o3-mini'])(
    'injects reasoning_effort and omits system+temperature for o-series model %s',
    (model) => {
      const params = resolve(model, 'auto');
      expect(params.extraBody).toEqual({ reasoning_effort: 'medium' });
      expect(params.omitSystem).toBe(true);
      expect(params.omitTemperature).toBe(true);
    },
  );

  it.each(['gpt-5', 'gpt-5.4', 'gpt-5.5', 'openai/gpt-5.4-mini'])(
    'omits temperature for OpenAI GPT-5-family model %s',
    (model) => {
      const params = resolve(model, 'auto');
      expect(params.extraBody).toEqual({});
      expect(params.omitSystem).toBe(false);
      expect(params.omitTemperature).toBe(true);
    },
  );

  it.each(['deepseek-r1', 'deepseek-reasoner', 'deepseek/deepseek-r1'])(
    'injects thinking:{type:enabled} for DeepSeek reasoning model %s',
    (model) => {
      const params = resolve(model, 'auto');
      expect(params.extraBody).toEqual({ thinking: { type: 'enabled' } });
      expect(params.omitSystem).toBe(false);
      expect(params.omitTemperature).toBe(false);
    },
  );

  it.each(['qwen3:8b', 'qwen3-72b', 'qwq-32b'])(
    'injects enable_thinking:true for Qwen3/QwQ model %s',
    (model) => {
      const params = resolve(model, 'auto');
      expect(params.extraBody).toEqual({ enable_thinking: true });
      expect(params.omitSystem).toBe(false);
    },
  );

  it('injects reasoning_effort for Gemini', () => {
    expect(resolve('gemini-2.5-pro', 'auto').extraBody).toEqual({ reasoning_effort: 'medium' });
  });

  it('injects nothing for an unknown model with auto mode (conservative)', () => {
    expect(resolve('some-unknown-model', 'auto')).toEqual({ extraBody: {}, omitSystem: false, omitTemperature: false });
  });

  it('does not treat GPT-4o as o-series or GPT-5-family', () => {
    const params = resolve('gpt-4o', 'auto');
    expect(params.omitSystem).toBe(false);
    expect(params.omitTemperature).toBe(false);
    expect(params.extraBody).toEqual({});
  });

  it('does not treat deepseek-v3 (non-reasoning) as a thinking model', () => {
    const params = resolve('deepseek-v3', 'auto');
    expect(params.extraBody).toEqual({});
  });
});


describe('OpenAICompatibleLlmService.translate() — thinking params', () => {
  function makeOSeriesService(model: string) {
    const settings = makeSettingsMock({ model, reasoningEffort: 'auto' });
    const httpService = { post: jest.fn(), axiosRef: { post: jest.fn() } };
    httpService.post.mockReturnValue(
      of({ data: { choices: [{ message: { content: 'translated' } }] } }),
    );
    const service = new OpenAICompatibleLlmService(
      httpService as unknown as HttpService,
      settings as unknown as SettingsService,
    );
    return { service, httpService, settings };
  }

  it('omits system role and temperature for o-series, adds reasoning_effort', async () => {
    const { service, httpService } = makeOSeriesService('o3-mini');

    await service.translate({ text: 'hello', targetLang: 'zh', systemPrompt: 'sys' });

    const body = httpService.post.mock.calls[0][1] as Record<string, unknown>;
    const messages = body.messages as Array<{ role: string; content: string }>;
    expect(messages.every((m) => m.role !== 'system')).toBe(true);
    expect(messages[0].content).toContain('sys');
    expect(body).not.toHaveProperty('temperature');
    expect(body).not.toHaveProperty('top_p');
    expect(body).toMatchObject({ reasoning_effort: 'medium' });
  });

  it('omits temperature for GPT-5-family models in auto mode', async () => {
    const { service, httpService } = makeOSeriesService('gpt-5.5');

    await service.translate({ text: 'hello', targetLang: 'zh', systemPrompt: 'sys' });

    const body = httpService.post.mock.calls[0][1] as Record<string, unknown>;
    const messages = body.messages as Array<{ role: string; content: string }>;
    expect(messages[0].role).toBe('system');
    expect(body).not.toHaveProperty('temperature');
    expect(body).not.toHaveProperty('top_p');
    expect(body).not.toHaveProperty('reasoning_effort');
  });

  it('sends normal system message and temperature when reasoningEffort is none', async () => {
    const { service, httpService } = makeOSeriesService('o3-mini');

    (service as unknown as { settingsService: { getTranslationConfig: jest.Mock } })
      .settingsService.getTranslationConfig.mockResolvedValue({ reasoningEffort: 'none' });

    await service.translate({ text: 'hello', targetLang: 'zh', systemPrompt: 'sys' });

    const body = httpService.post.mock.calls[0][1] as Record<string, unknown>;
    const messages = body.messages as Array<{ role: string; content: string }>;
    expect(messages[0].role).toBe('system');
    expect(body).toHaveProperty('temperature');
    expect(body).not.toHaveProperty('reasoning_effort');
  });
});


describe('OpenAICompatibleLlmService.parseStreamLine (private)', () => {
  const service = new OpenAICompatibleLlmService(
    {} as unknown as HttpService,
    {} as unknown as SettingsService,
  );
  const parse = (line: string) =>
    (service as unknown as { parseStreamLine: (l: string) => string | null }).parseStreamLine(line);

  it('returns null for an empty string', () => expect(parse('')).toBeNull());
  it('returns null for SSE comment lines (: ...)', () => expect(parse(': keep-alive')).toBeNull());
  it('returns null for non-data event lines', () => expect(parse('event: ping')).toBeNull());
  it('parses a data line with space after colon', () => expect(parse('data: {"k":"v"}')).toBe('{"k":"v"}'));
  it('parses a data line without space after colon', () => expect(parse('data:{"k":"v"}')).toBe('{"k":"v"}'));
  it('returns null for data: with only whitespace', () => expect(parse('data: ')).toBeNull());
  it('parses [DONE] payload', () => expect(parse('data: [DONE]')).toBe('[DONE]'));
});
