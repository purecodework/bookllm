


import { saveLlmConfig, getLlmConfig, testLlmConnection } from '@/lib/api';


function mockFetch(status: number, body: string, contentType = 'application/json') {
  global.fetch = jest.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers({ 'content-type': contentType }),
    text: () => Promise.resolve(body),
    json: () => Promise.resolve(body ? JSON.parse(body) : undefined),
  } as unknown as Response);
}

afterEach(() => {
  jest.restoreAllMocks();
});


describe('empty response body', () => {
  it('PUT with empty body does not throw JSON parse error', async () => {
    mockFetch(200, '');
    await expect(
      saveLlmConfig({ baseUrl: 'http://x/v1', apiKey: 'k', model: 'm' }),
    ).resolves.toBeUndefined();
  });

  it('204 No Content resolves to undefined without throwing', async () => {
    mockFetch(204, '');
    await expect(
      saveLlmConfig({ baseUrl: 'http://x/v1', apiKey: 'k', model: 'm' }),
    ).resolves.toBeUndefined();
  });
});


describe('JSON response', () => {
  it('GET returns parsed JSON', async () => {
    mockFetch(200, JSON.stringify({ baseUrl: 'http://x/v1', apiKey: 'k', model: 'gpt' }));
    const cfg = await getLlmConfig();
    expect(cfg.model).toBe('gpt');
    expect(cfg.baseUrl).toBe('http://x/v1');
  });

  it('models endpoint returns string array', async () => {
    const spy = jest.fn().mockResolvedValue({
      ok: true,
      status: 200,
      headers: new Headers({ 'content-type': 'application/json' }),
      text: () => Promise.resolve(JSON.stringify({ models: ['model-a', 'model-b'], provider: 'chatgpt' })),
      json: () => Promise.resolve({ models: ['model-a', 'model-b'], provider: 'chatgpt' }),
    } as unknown as Response);
    global.fetch = spy;
    const models = await testLlmConnection('http://x/v1', 'key');
    expect(models).toEqual({ models: ['model-a', 'model-b'], provider: 'chatgpt' });
    expect(spy).toHaveBeenCalledWith(
      expect.stringContaining('/settings/llm/models'),
      expect.objectContaining({
        method: 'PUT',
      }),
    );
  });

  it('does not fall back to the legacy GET models endpoint when PUT is unavailable', async () => {
    const spy = jest.fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 404,
        headers: new Headers({ 'content-type': 'application/json' }),
        text: () => Promise.resolve(JSON.stringify({ message: 'Not Found' })),
        json: () => Promise.resolve({ message: 'Not Found' }),
      } as unknown as Response);
    global.fetch = spy;

    await expect(testLlmConnection('http://x/v1', 'key')).rejects.toThrow('Not Found');

    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith(
      expect.stringContaining('/settings/llm/models'),
      expect.objectContaining({ method: 'PUT' }),
    );
  });
});


describe('error responses', () => {
  it('4xx throws with backend message', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 404,
      text: () => Promise.resolve(JSON.stringify({ message: '书籍不存在' })),
      json: () => Promise.resolve({ message: '书籍不存在' }),
    } as unknown as Response);
    await expect(getLlmConfig()).rejects.toThrow('书籍不存在');
  });

  it('4xx with empty body falls back to HTTP status message', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 500,
      text: () => Promise.resolve(''),
      json: () => Promise.reject(new Error('no json')),
    } as unknown as Response);
    await expect(getLlmConfig()).rejects.toThrow('HTTP 500');
  });

  it('prefers backend details over message when provided', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 500,
      text: () => Promise.resolve(JSON.stringify({
        message: '服务器内部错误',
        details: 'Incorrect API key provided: sk-veryverylongtoken123456',
      })),
      json: () => Promise.resolve({
        message: '服务器内部错误',
        details: 'Incorrect API key provided: sk-veryverylongtoken123456',
      }),
    } as unknown as Response);
    await expect(getLlmConfig()).rejects.toThrow('Incorrect API key provided: sk-***');
  });

  it('falls back to humanized businessCode when details/message are empty', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 422,
      text: () => Promise.resolve(JSON.stringify({
        businessCode: 'EPUB_NO_READABLE_CONTENT',
      })),
      json: () => Promise.resolve({
        businessCode: 'EPUB_NO_READABLE_CONTENT',
      }),
    } as unknown as Response);
    await expect(getLlmConfig()).rejects.toThrow('Epub No Readable Content');
  });

  it('appends businessCode and requestId for traceability', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 422,
      text: () => Promise.resolve(JSON.stringify({
        message: 'EPUB has no readable content',
        businessCode: 'EPUB_NO_READABLE_CONTENT',
        requestId: 'req-12345678',
      })),
      json: () => Promise.resolve({
        message: 'EPUB has no readable content',
        businessCode: 'EPUB_NO_READABLE_CONTENT',
        requestId: 'req-12345678',
      }),
    } as unknown as Response);
    await expect(getLlmConfig()).rejects.toThrow('EPUB has no readable content [EPUB_NO_READABLE_CONTENT] (Request: req-12345678)');
  });
});
