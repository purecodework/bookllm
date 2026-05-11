import { GlossaryService } from './glossary.service';
import { type PrismaService } from '../prisma/prisma.service';
import { type LlmService } from '../llm/llm.service';

jest.mock('../common/logging/app-logger', () => ({
  logInfo: jest.fn(),
  logWarn: jest.fn(),
  logError: jest.fn(),
}));

function makePrismaMock() {
  return {
    book: {
      findUnique: jest.fn().mockResolvedValue({ glossary: {} }),
    },
    $executeRawUnsafe: jest.fn().mockResolvedValue(undefined),
  };
}

function makeLlmMock() {
  return {
    translate: jest.fn().mockResolvedValue({
      translatedText: '[]',
      provider: 'test',
      model: 'test-model',
    }),
    translateStream: jest.fn(),
  };
}

describe('GlossaryService', () => {
  let service: GlossaryService;
  let prisma: ReturnType<typeof makePrismaMock>;
  let llm: ReturnType<typeof makeLlmMock>;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma = makePrismaMock();
    llm = makeLlmMock();
    service = new GlossaryService(
      prisma as unknown as PrismaService,
      llm as unknown as LlmService,
    );
  });

  it('converts valid JSON-like values to a string glossary map', () => {
    expect(
      service.toGlossaryMap({
        Frodo: '佛罗多',
        empty: '',
        nested: { value: 'bad' },
      }),
    ).toEqual({ Frodo: '佛罗多' });
  });

  it('merges extracted terms with existing terms taking priority', () => {
    expect(
      service.mergeGlossaries(
        { Frodo: '佛罗多' },
        { Frodo: '弗罗多', Gandalf: '甘道夫' },
      ),
    ).toMatchObject({
      version: 2,
      entries: expect.arrayContaining([
        expect.objectContaining({ source: 'Frodo', target: '佛罗多' }),
        expect.objectContaining({ source: 'Gandalf', target: '甘道夫' }),
      ]),
    });
  });

  describe('extractGlossaryTerms', () => {
    it('calls the LLM and returns a parsed glossary map', async () => {
      llm.translate.mockResolvedValueOnce({
        translatedText: '[{"source":"Frodo","target":"佛罗多"}]',
        provider: 'test',
        model: 'test-model',
      });

      const result = await service.extractGlossaryTerms(
        'Frodo walked through The Shire.',
        'zh',
        {},
      );

      expect(service.toGlossaryMap(result)).toEqual({ Frodo: '佛罗多' });
      const callArg = llm.translate.mock.calls[0][0] as { text: string; systemPrompt: string };
      expect(callArg.text).toContain('Extract proper nouns');
      expect(callArg.systemPrompt).toContain('Return only a valid JSON object');
    });

    it('returns an empty map when the LLM output is malformed', async () => {
      llm.translate.mockResolvedValueOnce({
        translatedText: 'not json',
        provider: 'test',
        model: 'test-model',
      });

      await expect(
        service.extractGlossaryTerms('No useful names.', 'zh', {}),
      ).resolves.toMatchObject({ version: 2, entries: [] });
    });

    it('returns an empty map for empty source text without calling the LLM', async () => {
      await expect(
        service.extractGlossaryTerms('', 'zh', {}),
      ).resolves.toMatchObject({ version: 2, entries: [] });
      expect(llm.translate).not.toHaveBeenCalled();
    });

    it('passes existing glossary keys to the prompt so the LLM skips already-known terms', async () => {
      llm.translate.mockResolvedValueOnce({ translatedText: '[]', provider: 'test', model: 'test-model' });

      await service.extractGlossaryTerms('Frodo met Gandalf.', 'zh', { Frodo: '佛罗多' });

      const callArg = llm.translate.mock.calls[0][0] as { text: string };
      expect(callArg.text).toContain('Frodo');
    });
  });

  describe('extractGlossaryTerms — truncation recovery', () => {
    it('salvages partial entries and calls continuation when response is truncated', async () => {
      const truncated = '[{"source":"Gandalf","target":"甘道夫"},{"source":"Shire","targ';
      const continuation = '[{"source":"Shire","target":"夏尔","type":"place"}]';

      llm.translate
        .mockResolvedValueOnce({ translatedText: truncated, provider: 'test', model: 'test' })
        .mockResolvedValueOnce({ translatedText: continuation, provider: 'test', model: 'test' });

      const result = await service.extractGlossaryTerms('Gandalf and The Shire.', 'zh', {});

      expect(service.toGlossaryMap(result)).toMatchObject({ Gandalf: '甘道夫', Shire: '夏尔' });
      expect(llm.translate).toHaveBeenCalledTimes(2);
    });

    it('returns partial entries even when continuation call fails', async () => {
      const truncated = '[{"source":"Gandalf","target":"甘道夫"},{"source":"Shire","targ';

      llm.translate
        .mockResolvedValueOnce({ translatedText: truncated, provider: 'test', model: 'test' })
        .mockRejectedValueOnce(new Error('continuation timeout'));

      const result = await service.extractGlossaryTerms('text', 'zh', {});

      expect(service.toGlossaryMap(result)).toEqual({ Gandalf: '甘道夫' });
    });

    it('does not call continuation for a clean empty response', async () => {
      llm.translate.mockResolvedValue({ translatedText: '[]', provider: 'test', model: 'test' });

      await service.extractGlossaryTerms('text', 'zh', {});

      expect(llm.translate).toHaveBeenCalledTimes(1);
    });
  });

  describe('extractBookContextFromSegments', () => {
    it('uses structured section extraction and preserves section summaries', async () => {
      llm.translate.mockResolvedValueOnce({
        translatedText: JSON.stringify({
          version: 2,
          entries: [{ source: 'Alice Liddell', target: '爱丽丝', type: 'character', aliases: ['Alice'] }],
          doNotTranslate: [],
          forbiddenTranslations: [],
          styleGuide: {},
          chapterSummaries: [],
          sections: [{ id: 'section_0001', pageStart: 1, pageEnd: 2, summary: 'Alice meets Moriarty.' }],
        }),
        provider: 'test',
        model: 'test',
      });

      const result = await service.extractBookContextFromSegments(
        [{
          sectionId: 'section_0001',
          pageStart: 1,
          pageEnd: 2,
          sourceText: '[SECTION id="section_0001" pageStart="1" pageEnd="2"]\nAlice Liddell met Moriarty.',
        }],
        'zh',
        undefined,
      );

      expect(result.entries[0]).toMatchObject({ source: 'Alice Liddell', target: '爱丽丝' });
      expect(result.sections[0]).toMatchObject({ id: 'section_0001', summary: 'Alice meets Moriarty.' });
      expect(llm.translate).toHaveBeenCalledWith(
        expect.objectContaining({
          text: expect.stringContaining('Section text:'),
          systemPrompt: expect.stringContaining('Return only a valid JSON object'),
        }),
      );
    });

    it('falls back to local merge when reduce fails', async () => {
      llm.translate
        .mockResolvedValueOnce({
          translatedText: JSON.stringify({
            version: 2,
            entries: [{ source: 'Alice', target: '爱丽丝', type: 'character', aliases: [] }],
            doNotTranslate: [],
            forbiddenTranslations: [],
            styleGuide: {},
            chapterSummaries: [],
            sections: [],
          }),
          provider: 'test',
          model: 'test',
        })
        .mockResolvedValueOnce({
          translatedText: JSON.stringify({
            version: 2,
            entries: [{ source: 'Moriarty', target: '莫里亚蒂', type: 'character', aliases: [] }],
            doNotTranslate: [],
            forbiddenTranslations: [],
            styleGuide: {},
            chapterSummaries: [],
            sections: [],
          }),
          provider: 'test',
          model: 'test',
        })
        .mockRejectedValueOnce(new Error('reduce failed'));

      const result = await service.extractBookContextFromSegments(
        [
          { sectionId: 'section_0001', sourceText: '[SECTION id="section_0001"]\nAlice appears.' },
          { sectionId: 'section_0002', sourceText: '[SECTION id="section_0002"]\nMoriarty appears.' },
        ],
        'zh',
        undefined,
      );

      expect(result.entries.map((entry) => entry.source).sort()).toEqual(['Alice', 'Moriarty']);
      expect(llm.translate).toHaveBeenCalledTimes(3);
    });

    it('runs section map calls concurrently when concurrency is greater than one', async () => {
      let resolveFirst!: (value: { translatedText: string; provider: string; model: string }) => void;
      const first = new Promise<{ translatedText: string; provider: string; model: string }>((resolve) => {
        resolveFirst = resolve;
      });
      llm.translate
        .mockReturnValueOnce(first)
        .mockResolvedValueOnce({
          translatedText: JSON.stringify({
            version: 2,
            entries: [{ source: 'Moriarty', target: '莫里亚蒂', type: 'character', aliases: [] }],
            doNotTranslate: [],
            forbiddenTranslations: [],
            styleGuide: {},
            chapterSummaries: [],
            sections: [],
          }),
          provider: 'test',
          model: 'test',
        })
        .mockRejectedValueOnce(new Error('reduce failed'));

      const pending = service.extractBookContextFromSegments(
        [
          { sectionId: 'section_0001', sourceText: '[SECTION id="section_0001"]\nAlice appears.' },
          { sectionId: 'section_0002', sourceText: '[SECTION id="section_0002"]\nMoriarty appears.' },
        ],
        'zh',
        undefined,
        2,
      );

      await new Promise((resolve) => setImmediate(resolve));
      expect(llm.translate).toHaveBeenCalledTimes(2);
      resolveFirst({
        translatedText: JSON.stringify({
          version: 2,
          entries: [{ source: 'Alice', target: '爱丽丝', type: 'character', aliases: [] }],
          doNotTranslate: [],
          forbiddenTranslations: [],
          styleGuide: {},
          chapterSummaries: [],
          sections: [],
        }),
        provider: 'test',
        model: 'test',
      });

      const result = await pending;
      expect(result.entries.map((entry) => entry.source).sort()).toEqual(['Alice', 'Moriarty']);
    });
  });
});
