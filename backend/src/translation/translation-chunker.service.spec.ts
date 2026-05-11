import { TranslationChunkerService } from './translation-chunker.service';
import { type LlmService } from '../llm/llm.service';
import { type SettingsService } from '../settings/settings.service';


function makeLlmMock() {
  return {
    translate: jest.fn().mockImplementation(({ text }: { text: string }) =>
      Promise.resolve({
        translatedText: `[TRANSLATED] ${text}`,
        provider: 'omlx',
        model: 'test-model',
      }),
    ),
    translateStream: jest.fn().mockImplementation(async function* ({ text }: { text: string }) {
      yield `[TRANSLATED] ${text}`;
    }),
  };
}

function makeSettingsMock() {
  return {
    getTranslationConfig: jest.fn().mockResolvedValue({
      inputTokenBudget: 1200,
      contextWindowTokens: 8192,
      concurrency: 1,
      stylePrompt: '',
    }),
  };
}

describe('TranslationChunkerService', () => {
  let service: TranslationChunkerService;
  let llm: ReturnType<typeof makeLlmMock>;

  beforeEach(() => {
    llm = makeLlmMock();
    service = new TranslationChunkerService(
      llm as unknown as LlmService,
      makeSettingsMock() as unknown as SettingsService,
    );
  });

  describe('splitIntoChunks', () => {
    it('returns empty array for empty input', async () => {
      expect(await service.splitIntoChunks('')).toHaveLength(0);
      expect(await service.splitIntoChunks('   ')).toHaveLength(0);
    });

    it('keeps a short single-paragraph text as one chunk', async () => {
      const text = '这是一段简短的文字。';
      const chunks = await service.splitIntoChunks(text);

      expect(chunks).toHaveLength(1);
      expect(chunks[0].index).toBe(0);
      expect(chunks[0].text).toBe(text);
      expect(chunks[0].contextTail).toBe('');
    });

    it('merges multi-paragraph short text into a single chunk (total < 1000 tokens)', async () => {
      const text = '第一段。\n\n第二段。\n\n第三段。';
      const chunks = await service.splitIntoChunks(text);

      expect(chunks).toHaveLength(1);
      expect(chunks[0].text).toContain('第一段');
      expect(chunks[0].text).toContain('第三段');
    });

    it('splits long text into multiple chunks', async () => {
      const para = '字'.repeat(400);
      const text = [para, para, para].join('\n\n');
      const chunks = await service.splitIntoChunks(text);

      expect(chunks.length).toBeGreaterThanOrEqual(2);
    });

    it('subsequent chunks carry the contextTail from the previous chunk (≤ 350 chars)', async () => {
      const para = '字'.repeat(400);
      const text = [para, para, para].join('\n\n');
      const chunks = await service.splitIntoChunks(text);

      expect(chunks[0].contextTail).toBe('');
      expect(chunks[1].contextTail.length).toBeGreaterThan(0);
      expect(chunks[1].contextTail.length).toBeLessThanOrEqual(350);
    });

    it('chunk indices are consecutive starting from 0', async () => {
      const para = '字'.repeat(400);
      const text = [para, para, para].join('\n\n');
      const chunks = await service.splitIntoChunks(text);

      chunks.forEach((c, i) => expect(c.index).toBe(i));
    });

    it('splits a long Chinese paragraph without double newlines', async () => {
      const settingsMock = {
        getTranslationConfig: jest.fn().mockResolvedValue({
          inputTokenBudget: 200,
          contextWindowTokens: 8192,
          concurrency: 1,
          stylePrompt: '',
        }),
      };
      service = new TranslationChunkerService(
        llm as unknown as LlmService,
        settingsMock as unknown as SettingsService,
      );
      const sentence = '这是一个测试句子，用于验证切分逻辑是否正确工作。';
      const text = sentence.repeat(50);

      const chunks = await service.splitIntoChunks(text);

      expect(chunks.length).toBeGreaterThanOrEqual(2);
    });

    it('splits a long English paragraph without double newlines', async () => {
      const sentence = 'This is a test sentence used to verify that the splitter works correctly. ';
      const text = sentence.repeat(220);

      const chunks = await service.splitIntoChunks(text);

      expect(chunks.length).toBeGreaterThanOrEqual(2);
    });

    it('paragraph boundary (\\n\\n) takes precedence over sentence boundary', async () => {
      const settingsMock = {
        getTranslationConfig: jest.fn().mockResolvedValue({
          inputTokenBudget: 120,
          contextWindowTokens: 2048,
          concurrency: 1,
          stylePrompt: '',
        }),
      };
      service = new TranslationChunkerService(
        llm as unknown as LlmService,
        settingsMock as unknown as SettingsService,
      );


      const para1 = '第一段落开始。' + '内容文字'.repeat(150) + '第一段落结束。';
      const para2 = '第二段落开始。' + '内容文字'.repeat(150) + '第二段落结束。';
      const text = `${para1}\n\n${para2}`;

      const chunks = await service.splitIntoChunks(text);

      expect(chunks.length).toBeGreaterThanOrEqual(2);
      expect(chunks[0].text).toContain('第一段落开始');
      expect(chunks.some((c) => c.text.includes('第二段落开始'))).toBe(true);
    });

    it('does not pad short text to 1024 tokens', async () => {
      const text = 'short text';
      const chunks = await service.splitIntoChunks(text);
      expect(chunks).toHaveLength(1);
      expect(chunks[0].text).toBe(text);
    });

    it('returns at least one chunk when inputTokenBudget is below minimum', async () => {
      const settingsMock = {
        getTranslationConfig: jest.fn().mockResolvedValue({
          inputTokenBudget: 64,
          contextWindowTokens: 8192,
          concurrency: 1,
          stylePrompt: '',
        }),
      };
      service = new TranslationChunkerService(
        llm as unknown as LlmService,
        settingsMock as unknown as SettingsService,
      );

      const chunks = await service.splitIntoChunks('这是测试文本。'.repeat(20), {
        sourceLang: 'zh',
        targetLang: 'en',
        chapterTitle: 'A',
      });
      expect(chunks.length).toBeGreaterThanOrEqual(1);
    });

    it('throws a clear budget error when context window is too small for fixed overhead', async () => {
      const settingsMock = {
        getTranslationConfig: jest.fn().mockResolvedValue({
          inputTokenBudget: 1024,
          contextWindowTokens: 128,
          concurrency: 1,
          stylePrompt: '',
        }),
      };
      service = new TranslationChunkerService(
        llm as unknown as LlmService,
        settingsMock as unknown as SettingsService,
      );

      await expect(
        service.splitIntoChunks('这是测试文本。'.repeat(20), {
          sourceLang: 'zh',
          targetLang: 'en',
        }),
      ).rejects.toThrow('TRANSLATION_CHUNK_BUDGET_EXCEEDED');
    });
  });

  describe('translatePage', () => {
    it('returns the concatenated full translation', async () => {
      const result = await service.translatePage({
        sourceText: '第一段。\n\n第二段。',
        sourceLang: 'zh',
        targetLang: 'en',
      });

      expect(typeof result).toBe('string');
      expect(result.length).toBeGreaterThan(0);
    });

    it('returns empty string for empty source text', async () => {
      const result = await service.translatePage({
        sourceText: '',
        sourceLang: 'zh',
        targetLang: 'en',
      });

      expect(result).toBe('');
      expect(llm.translate).not.toHaveBeenCalled();
    });

    it('calls llm.translate once per chunk', async () => {
      const para = '字'.repeat(400);
      const text = [para, para, para].join('\n\n');
      const chunks = await service.splitIntoChunks(text);

      await service.translatePage({ sourceText: text, sourceLang: 'zh', targetLang: 'en' });

      expect(llm.translate).toHaveBeenCalledTimes(chunks.length);
    });

    it('calls onChunkDone after each chunk with the correct total', async () => {
      const para = '字'.repeat(400);
      const text = [para, para, para].join('\n\n');
      const chunkCount = (await service.splitIntoChunks(text)).length;
      const onChunkDone = jest.fn();

      await service.translatePage(
        { sourceText: text, sourceLang: 'zh', targetLang: 'en' },
        onChunkDone,
      );

      expect(onChunkDone).toHaveBeenCalledTimes(chunkCount);
      onChunkDone.mock.calls.forEach(([, total]: [unknown, number]) => {
        expect(total).toBe(chunkCount);
      });
    });

    it('injects chapter title into the prompt when provided', async () => {
      await service.translatePage({
        sourceText: '测试内容',
        sourceLang: 'zh',
        targetLang: 'en',
        chapterTitle: '黑暗森林',
      });

      const callArg = llm.translate.mock.calls[0][0] as { text: string };
      expect(callArg.text).toContain('黑暗森林');
    });

    it('systemPrompt contains the language pair and output-only constraint', async () => {
      await service.translatePage({
        sourceText: '测试',
        sourceLang: 'zh',
        targetLang: 'en',
      });

      const callArg = llm.translate.mock.calls[0][0] as { systemPrompt: string };
      expect(callArg.systemPrompt).toContain('zh');
      expect(callArg.systemPrompt).toContain('en');
      expect(callArg.systemPrompt).toContain('Output only the translation');
    });

    it('does not send custom style prompt to the primary translation model', async () => {
      const settingsMock = {
        getTranslationConfig: jest.fn().mockResolvedValue({
          inputTokenBudget: 1000,
          contextWindowTokens: 8192,
          concurrency: 1,
          stylePrompt: '语气更冷峻。\n请翻译成英文。',
        }),
      };
      service = new TranslationChunkerService(
        llm as unknown as LlmService,
        settingsMock as unknown as SettingsService,
      );

      await service.translatePage({
        sourceText: '测试',
        sourceLang: 'zh',
        targetLang: 'ja',
      });

      const callArg = llm.translate.mock.calls[0][0] as { systemPrompt: string };
      expect(callArg.systemPrompt).toContain('MUST be ja');
      expect(callArg.systemPrompt).not.toContain('语气更冷峻');
      expect(callArg.systemPrompt).not.toContain('请翻译成英文');
    });

    it('injects relevant glossary terms into chunk translation prompts', async () => {
      await service.translatePage({
        sourceText: 'Frodo walked through the forest.',
        sourceLang: 'en',
        targetLang: 'zh',
        glossary: { Frodo: '佛罗多', Gandalf: '甘道夫' },
      });

      const callArg = llm.translate.mock.calls[0][0] as { systemPrompt: string };
      expect(callArg.systemPrompt).toContain('Frodo → 佛罗多');
      expect(callArg.systemPrompt).not.toContain('Gandalf → 甘道夫');
    });
  });

});
