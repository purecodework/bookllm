export type ChapterStatus = 'pending' | 'processing' | 'completed' | 'failed';

export interface ChapterProgressResult {
  progress: number;
  status: ChapterStatus;
}


export function computeChapterProgress(
  translated: number,
  total: number,
  failed = 0,
): ChapterProgressResult {
  if (total === 0) return { progress: 0, status: 'pending' };
  const progress = Math.round((translated / total) * 100);
  if (translated < total && translated + failed >= total && failed > 0) {
    return { progress, status: 'failed' };
  }
  const status: ChapterStatus =
    translated === 0 ? 'pending' : translated < total ? 'processing' : 'completed';
  return { progress, status };
}
