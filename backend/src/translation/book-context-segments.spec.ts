import {
  buildBookContextSegmentsFromPages,
  resolveBookContextSectionTokenTarget,
} from './book-context-segments';

describe('book context section builder', () => {
  it('uses the planned token target for an 8192 context window', () => {
    expect(resolveBookContextSectionTokenTarget(8192)).toBe(4505);
  });

  it('caps section target by input token budget for faster glossary map calls', () => {
    expect(resolveBookContextSectionTokenTarget(8192, 2000)).toBe(2000);
  });

  it('builds sections from sourceText pages without requiring OCR-specific state', () => {
    const sections = buildBookContextSegmentsFromPages(
      [
        { pageNumber: 1, sourceText: 'Alice meets NASA.' },
        { pageNumber: 2, sourceText: 'Bob enters the observatory.' },
      ],
      8192,
    );

    expect(sections).toHaveLength(1);
    expect(sections[0]).toMatchObject({
      sectionId: 'section_0001',
      pageStart: 1,
      pageEnd: 2,
    });
    expect(sections[0].sourceText).toContain('[SECTION id="section_0001" pageStart="1" pageEnd="2"]');
    expect(sections[0].sourceText).toContain('[PAGE page="1"]');
  });

  it('keeps chapter metadata and starts a new section at chapter boundaries', () => {
    const sections = buildBookContextSegmentsFromPages(
      [
        {
          pageNumber: 1,
          sourceText: 'Chapter one text.',
          chapter: { id: 'ch_1', title: 'One', chapterNumber: 1 },
        },
        {
          pageNumber: 2,
          sourceText: 'Chapter two text.',
          chapter: { id: 'ch_2', title: 'Two', chapterNumber: 2 },
        },
      ],
      8192,
    );

    expect(sections).toHaveLength(2);
    expect(sections[0]).toMatchObject({ chapterId: 'ch_1', title: 'One', pageStart: 1, pageEnd: 1 });
    expect(sections[1]).toMatchObject({ chapterId: 'ch_2', title: 'Two', pageStart: 2, pageEnd: 2 });
  });

  it('splits long no-chapter material by token budget', () => {
    const longPage = Array.from({ length: 900 }, (_, i) => `Paragraph ${i} with Alice and Observatory.`).join('\n\n');
    const sections = buildBookContextSegmentsFromPages(
      [{ pageNumber: 1, sourceText: longPage }],
      1024,
    );

    expect(sections.length).toBeGreaterThan(1);
    expect(sections.every((section) => section.pageStart === 1 && section.pageEnd === 1)).toBe(true);
  });
});
