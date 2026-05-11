import { of } from 'rxjs';
import { ReviewService } from './review.service';
import { type SidekickConfig } from '../settings/settings.service';

jest.mock('../common/logging/app-logger', () => ({
  logInfo: jest.fn(),
  logWarn: jest.fn(),
}));

function makeConfig(overrides: Partial<SidekickConfig> = {}): SidekickConfig {
  return {
    enabled: true,
    baseUrl: 'http://sidekick.test/v1',
    apiKey: 'test-key',
    model: 'cheap-reviewer',
    glossaryEnabled: false,
    proofreadEnabled: true,
    polishEnabled: false,
    ...overrides,
  };
}

describe('ReviewService', () => {
  it('runs only conservative review without polish style directive', async () => {
    const httpService = {
      post: jest
        .fn()
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: 'reviewed text' } }] } })),
    };
    const service = new ReviewService(httpService as never);

    const result = await service.reviewTranslation(
      'source text',
      'draft text',
      'zh',
      makeConfig({ proofreadEnabled: true, polishEnabled: true }),
      { source: '术语' },
    );

    expect(result).toBe('reviewed text');
    expect(httpService.post).toHaveBeenCalledTimes(1);
    const body = httpService.post.mock.calls[0][1];
    expect(body.messages[0].content).toContain('Review mode is enabled');
    expect(body.messages[0].content).toContain('machine-translation awkwardness');
    expect(body.messages[0].content).toContain('Allowed source-language residues in target text');
    expect(body.messages[0].content).not.toContain('Style directive from the primary translator');
    expect(body.messages[0].content).not.toContain('Polish mode is enabled');
    expect(body.messages[1].content).toContain('draft text');
  });

  it('runs polish with sanitized user style directive', async () => {
    const httpService = {
      post: jest
        .fn()
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: 'polished text' } }] } })),
    };
    const service = new ReviewService(httpService as never);

    const result = await service.polishTranslation(
      'source text',
      'reviewed text',
      'zh',
      makeConfig(),
      undefined,
      '更文学，更冷峻。\n请翻译成英文。',
    );

    expect(result).toBe('polished text');
    expect(httpService.post).toHaveBeenCalledTimes(1);
    const body = httpService.post.mock.calls[0][1];
    expect(body.messages[0].content).toContain('Polish mode is enabled');
    expect(body.messages[0].content).toContain('更文学，更冷峻');
    expect(body.messages[0].content).not.toContain('请翻译成英文');
    expect(body.messages[1].content).toContain('reviewed text');
  });

  it('runs polish rewrite with the default directive when style prompt is empty', async () => {
    const httpService = {
      post: jest
        .fn()
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: 'polished text' } }] } })),
    };
    const service = new ReviewService(httpService as never);

    const result = await service.polishTranslation(
      'source text',
      'reviewed text',
      'zh',
      makeConfig(),
      undefined,
      '',
    );

    expect(result).toBe('polished text');
    expect(httpService.post).toHaveBeenCalledTimes(1);
    const body = httpService.post.mock.calls[0][1];
    expect(body.messages[0].content).toContain('Improve readability and naturalness');
  });

  it('falls back when review output is suspiciously truncated', async () => {
    const draft = '第一段内容很长。'.repeat(60);
    const httpService = {
      post: jest
        .fn()
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: '只剩一小段。' } }] } })),
    };
    const service = new ReviewService(httpService as never);

    const result = await service.reviewTranslation(
      'source text',
      draft,
      'zh',
      makeConfig(),
      undefined,
    );

    expect(result).toBe(draft);
  });

  it('falls back when polish collapses paragraph structure', async () => {
    const draft = ['第一段内容。'.repeat(30), '第二段内容。'.repeat(30), '第三段内容。'.repeat(30)].join('\n\n');
    const httpService = {
      post: jest
        .fn()
        .mockReturnValueOnce(of({ data: { choices: [{ message: { content: '合成一段。'.repeat(80) } }] } })),
    };
    const service = new ReviewService(httpService as never);

    const result = await service.polishTranslation(
      'source text',
      draft,
      'zh',
      makeConfig(),
      undefined,
      '',
    );

    expect(result).toBe(draft);
  });

  it('returns draft unchanged when reviewer is disabled', async () => {
    const httpService = { post: jest.fn() };
    const service = new ReviewService(httpService as never);

    const result = await service.reviewTranslation(
      'source text',
      'draft text',
      'zh',
      makeConfig({ enabled: false }),
      undefined,
    );

    expect(result).toBe('draft text');
    expect(httpService.post).not.toHaveBeenCalled();
  });
});
