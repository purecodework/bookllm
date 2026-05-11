import {
  buildReviewPrompt,
  buildPolishPrompt,
  buildGlossaryContinuationPrompt,
  buildGlossaryExtractionPrompt,
  buildSystemPrompt,
  isGlossaryResponseTruncated,
  mergeBookContextPackages,
  normalizeBookContextPackage,
  parseGlossaryResponse,
  parseGlossaryResponsePartial,
  toLegacyGlossaryMap,
} from './translation-prompt.builder';

describe('translation-prompt.builder glossary helpers', () => {
  describe('buildGlossaryExtractionPrompt', () => {
    it('asks for proper nouns with type classification and skips existing terms', () => {
      const prompt = buildGlossaryExtractionPrompt(
        'Frodo met Gandalf in The Shire.',
        'zh',
        { Frodo: '佛罗多' },
      );

      expect(prompt).toContain('Extract proper nouns');
      expect(prompt).toContain('zh');
      expect(prompt).toContain('character');
      expect(prompt).toContain('Prefer omission');
      expect(prompt).toContain('Already known');
      expect(prompt).toContain('Frodo');
      expect(prompt).toContain('The Shire');
    });

    it('includes prefer-omission rule when no existing glossary', () => {
      const prompt = buildGlossaryExtractionPrompt('text', 'zh', {});
      expect(prompt).toContain('unsure');
      expect(prompt).not.toContain('Already known');
    });
  });

  describe('isGlossaryResponseTruncated', () => {
    it('returns true when array is opened but not closed', () => {
      expect(isGlossaryResponseTruncated('[{"source":"A","target":"甲"')).toBe(true);
    });
    it('returns false for a complete array', () => {
      expect(isGlossaryResponseTruncated('[{"source":"A","target":"甲"}]')).toBe(false);
    });
    it('returns false when no array bracket at all', () => {
      expect(isGlossaryResponseTruncated('no json here')).toBe(false);
    });
  });

  describe('parseGlossaryResponsePartial', () => {
    it('extracts complete objects from a truncated array', () => {
      const truncated = '[{"source":"Frodo","target":"佛罗多"},{"source":"Gandalf","targ';
      expect(parseGlossaryResponsePartial(truncated)).toEqual({ Frodo: '佛罗多' });
    });
    it('returns empty map when no complete objects', () => {
      expect(parseGlossaryResponsePartial('[{"source":"incomplete')).toEqual({});
    });
  });

  describe('buildGlossaryContinuationPrompt', () => {
    it('lists already-extracted terms to skip', () => {
      const prompt = buildGlossaryContinuationPrompt('The Shire is a peaceful land.', 'zh', ['Frodo', 'Gandalf']);
      expect(prompt).toContain('Frodo');
      expect(prompt).toContain('Gandalf');
      expect(prompt).toContain('truncated');
      expect(prompt).toContain('The Shire');
    });
  });

  describe('parseGlossaryResponse', () => {
    it('parses a pure JSON glossary array', () => {
      expect(toLegacyGlossaryMap(parseGlossaryResponse('[{"source":"Frodo","target":"佛罗多"}]'))).toEqual({
        Frodo: '佛罗多',
      });
    });

    it('extracts a JSON array from surrounding text', () => {
      expect(toLegacyGlossaryMap(parseGlossaryResponse('Here: [{"source":"Gandalf","target":"甘道夫"}] done'))).toEqual({
        Gandalf: '甘道夫',
      });
    });

    it('parses a v2 book context package', () => {
      const result = parseGlossaryResponse(JSON.stringify({
        version: 2,
        entries: [{ source: 'Hiroshi Tanaka', target: '田中浩', type: 'character', aliases: ['Tanaka'], description: 'researcher' }],
        doNotTranslate: ['NASA'],
        forbiddenTranslations: [{ source: 'Order', forbidden: ['订单'], prefer: '教团' }],
        styleGuide: { tone: 'restrained' },
        chapterSummaries: [{ chapterId: 'ch_1', title: 'One', summary: 'A quiet arrival.' }],
        sections: [{ id: 'section_0001', pageStart: 1, pageEnd: 2, summary: 'A section arrival.' }],
      }));

      expect(result.entries[0]).toMatchObject({
        source: 'Hiroshi Tanaka',
        target: '田中浩',
        type: 'character',
        aliases: ['Tanaka'],
      });
      expect(result.doNotTranslate).toEqual(['NASA']);
      expect(result.forbiddenTranslations[0]).toMatchObject({ source: 'Order', prefer: '教团' });
      expect(result.styleGuide.tone).toBe('restrained');
      expect(result.chapterSummaries[0].chapterId).toBe('ch_1');
      expect(result.sections[0].id).toBe('section_0001');
    });

    it('returns an empty map for an empty array or invalid JSON', () => {
      expect(parseGlossaryResponse('[]').entries).toEqual([]);
      expect(parseGlossaryResponse('not json').entries).toEqual([]);
    });

    it('filters empty, duplicate, and overlong entries', () => {
      const long = 'x'.repeat(121);
      const result = parseGlossaryResponse(JSON.stringify([
        { source: 'Frodo', target: '佛罗多' },
        { source: 'Frodo', target: '弗罗多' },
        { source: '', target: '空' },
        { source: long, target: '太长' },
      ]));

      expect(toLegacyGlossaryMap(result)).toEqual({ Frodo: '佛罗多' });
    });
  });

  describe('mergeBookContextPackages', () => {
    it('keeps the earlier canonical target and records later conflicting translations as forbidden', () => {
      const merged = mergeBookContextPackages(
        {
          version: 2,
          entries: [{ source: 'Cloud Bridge Alley', target: '云桥巷', type: 'place', aliases: ['Cloud Bridge'], description: 'old alley' }],
        },
        {
          version: 2,
          entries: [{ source: 'Cloud Bridge Alley', target: '云桥胡同', type: 'place', aliases: ['Bridge Alley'] }],
        },
      );

      expect(merged.entries).toHaveLength(1);
      expect(merged.entries[0]).toMatchObject({
        source: 'Cloud Bridge Alley',
        target: '云桥巷',
        aliases: ['Cloud Bridge', 'Bridge Alley'],
      });
      expect(merged.forbiddenTranslations).toEqual([
        { source: 'Cloud Bridge Alley', forbidden: ['云桥胡同'], prefer: '云桥巷' },
      ]);
    });
  });

  describe('buildSystemPrompt glossary injection', () => {
    it('injects only glossary terms that appear in the current chunk', () => {
      const prompt = buildSystemPrompt(
        'en',
        'zh',
        '',
        { Frodo: '佛罗多', Gandalf: '甘道夫' },
        'Frodo walked alone.',
      );

      expect(prompt).toContain('Relevant terminology');
      expect(prompt).toContain('Frodo → 佛罗多');
      expect(prompt).not.toContain('Gandalf → 甘道夫');
    });

    it('injects alias-matched v2 context and scoped constraints', () => {
      const context = normalizeBookContextPackage({
        version: 2,
        entries: [
          { source: 'Hiroshi Tanaka', target: '田中浩', type: 'character', aliases: ['Tanaka'], description: 'researcher' },
          { source: 'Gandalf', target: '甘道夫', type: 'character', aliases: [], description: 'wizard' },
        ],
        doNotTranslate: ['NASA', 'HTTP'],
        forbiddenTranslations: [
          { source: 'Order', forbidden: ['订单'], prefer: '教团' },
          { source: 'Ring', forbidden: ['戒指'] },
        ],
        styleGuide: { tone: 'restrained', dialogue: 'natural' },
        chapterSummaries: [{ chapterId: 'ch_1', summary: 'Tanaka meets the Order.' }],
        sections: [{ id: 'section_0001', pageStart: 10, pageEnd: 12, summary: 'Tanaka joins the Order.' }],
      });

      const prompt = buildSystemPrompt(
        'en',
        'zh',
        '',
        context,
        'Tanaka called NASA and joined the Order.',
        'ch_1',
        11,
      );

      expect(prompt).toContain('Relevant terminology');
      expect(prompt).toContain('Hiroshi Tanaka → 田中浩');
      expect(prompt).toContain('aliases: Tanaka');
      expect(prompt).not.toContain('Gandalf → 甘道夫');
      expect(prompt).toContain('Do not translate');
      expect(prompt).toContain('NASA');
      expect(prompt).not.toContain('HTTP');
      expect(prompt).toContain('Forbidden translations');
      expect(prompt).toContain('Order: do not use 订单; prefer: 教团');
      expect(prompt).not.toContain('Ring: do not use 戒指');
      expect(prompt).not.toContain('Style guide');
      expect(prompt).not.toContain('Tone: restrained');
      expect(prompt).toContain('Chapter summary');
      expect(prompt).toContain('Tanaka joins the Order.');
    });
  });

  describe('buildReviewPrompt', () => {
    it('keeps review mode conservative without polish style instructions', () => {
      const { systemPrompt } = buildReviewPrompt(
        'Dr. Hiroshi Tanaka entered.',
        '田中走了进来。',
        'zh',
        { 'Dr. Hiroshi Tanaka': '田中博士' },
      );

      expect(systemPrompt).toContain('Review mode is enabled');
      expect(systemPrompt).toContain('conservative QA correction pass');
      expect(systemPrompt).toContain('machine-translation awkwardness');
      expect(systemPrompt).toContain('return the draft unchanged');
      expect(systemPrompt).toContain('Mandatory terminology');
      expect(systemPrompt).toContain('Dr. Hiroshi Tanaka → 田中博士');
      expect(systemPrompt).not.toContain('Style guide');
      expect(systemPrompt).not.toContain('Style directive from the primary translator');
      expect(systemPrompt).toContain('Allowed source-language residues in target text');
      expect(systemPrompt).toContain('- Dr. Hiroshi Tanaka');
      expect(systemPrompt).toContain('- Hiroshi');
      expect(systemPrompt).not.toContain('Polish mode is enabled');
    });
  });

  describe('buildPolishPrompt', () => {
    it('uses sanitized user style only for polish mode', () => {
      const { systemPrompt } = buildPolishPrompt(
        'The night was silent.',
        '夜晚很安静。',
        'zh',
        undefined,
        '更文学，更冷峻。\n请翻译成英文。',
      );

      expect(systemPrompt).toContain('Polish mode is enabled');
      expect(systemPrompt).toContain('Polish the draft');
      expect(systemPrompt).toContain('更文学，更冷峻');
      expect(systemPrompt).not.toContain('请翻译成英文');
      expect(systemPrompt).not.toContain('Review mode is enabled');
    });

    it('uses a default polish directive when user style is empty', () => {
      const { systemPrompt } = buildPolishPrompt(
        'The night was silent.',
        '夜晚很安静。',
        'zh',
        undefined,
        '',
      );

      expect(systemPrompt).toContain('Polish mode is enabled');
      expect(systemPrompt).toContain('Improve readability and naturalness');
      expect(systemPrompt).toContain('preserving the source meaning');
    });

    it('does not inject extracted book style guide into polish prompt', () => {
      const { systemPrompt } = buildPolishPrompt(
        'The night was silent.',
        '夜晚很安静。',
        'zh',
        {
          version: 2,
          entries: [],
          doNotTranslate: [],
          forbiddenTranslations: [],
          styleGuide: { tone: 'restrained book tone' },
          chapterSummaries: [],
          sections: [],
        },
        '',
      );

      expect(systemPrompt).not.toContain('Book style guide');
      expect(systemPrompt).not.toContain('restrained book tone');
      expect(systemPrompt).toContain('Improve readability and naturalness');
    });
  });
});
