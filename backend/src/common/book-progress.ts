export function computeBookProgress(
  pages: Array<{ translationStatus: string | null | undefined }>,
): number {
  if (pages.length === 0) return 0;
  const completed = pages.filter((page) => page.translationStatus === 'completed').length;
  return Math.round((completed / pages.length) * 100);
}
