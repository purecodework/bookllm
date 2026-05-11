export function formatDuration(totalSeconds: number, locale: string): string {
  const seconds = Math.max(0, Math.round(totalSeconds));
  if (seconds < 60) {
    return locale === "zh" ? `约 ${seconds} 秒` : `~${seconds}s`;
  }
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) {
    return locale === "zh" ? `约 ${minutes} 分钟` : `~${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return locale === "zh" ? `约 ${hours}小时${rest}分钟` : `~${hours}h ${rest}m`;
}
