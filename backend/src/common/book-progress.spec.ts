import { computeBookProgress } from './book-progress';

describe('computeBookProgress', () => {
  it('returns 0 when the book has no pages', () => {
    expect(computeBookProgress([])).toBe(0);
  });

  it('counts only completed pages', () => {
    expect(
      computeBookProgress([
        { translationStatus: 'completed' },
        { translationStatus: 'processing' },
        { translationStatus: 'failed' },
        { translationStatus: 'completed' },
      ]),
    ).toBe(50);
  });
});
