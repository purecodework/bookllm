export function formatTokenCompact(count: number, locale = "en"): string {
  const safe = Math.max(0, Math.round(count));
  const format1 = (n: number) =>
    new Intl.NumberFormat(locale, {
      minimumFractionDigits: 1,
      maximumFractionDigits: 1,
    }).format(n);

  if (safe >= 1_000_000) return `${format1(safe / 1_000_000)}m`;
  if (safe >= 1_000) return `${format1(safe / 1_000)}k`;
  return String(safe);
}
