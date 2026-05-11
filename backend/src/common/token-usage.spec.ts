import { normalizeUsageByStage, persistBookUsageDelta } from './token-usage';

describe('token usage persistence', () => {
  it('normalizes stored stage totals', () => {
    expect(
      normalizeUsageByStage({
        translation: { inputTokens: 10.4, outputTokens: '20' },
        unknown: { inputTokens: 999, outputTokens: 999 },
      }),
    ).toEqual({
      translation: { inputTokens: 10, outputTokens: 20 },
    });
  });

  it('increments book totals and per-stage totals', async () => {
    const prisma = {
      book: {
        findUnique: jest.fn().mockResolvedValue({
          usageByStage: {
            translation: { inputTokens: 100, outputTokens: 50 },
          },
        }),
        update: jest.fn(),
      },
    };

    await persistBookUsageDelta(
      prisma as never,
      'book-1',
      'translation',
      { inputTokens: 25.2, outputTokens: 9.7 },
    );

    expect(prisma.book.update).toHaveBeenCalledWith({
      where: { id: 'book-1' },
      data: {
        usageInputTokens: { increment: 25 },
        usageOutputTokens: { increment: 10 },
        usageByStage: {
          translation: { inputTokens: 125, outputTokens: 60 },
        },
      },
    });
  });
});
