


export interface EtaResult {

  percentPerMin: number | undefined;

  etaSeconds: number | undefined;

  etaLabel: string | undefined;
}

export function formatEta(seconds: number, locale: "zh" | "en" = "zh"): string {
  const s = Math.round(seconds);
  const prefix = locale === "zh" ? "≈ " : "~ ";
  if (s < 60) return `${prefix}${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return rem > 0 ? `${prefix}${m}m ${rem}s` : `${prefix}${m}m`;
}


export function computeEta(
  progress: number,
  startedAt: string | null | undefined,
  nowMs: number = Date.now(),
  locale: "zh" | "en" = "zh",
  minElapsedSec = 5,
): EtaResult {
  if (!startedAt || progress <= 0) {
    return {
      percentPerMin: undefined,
      etaSeconds: undefined,
      etaLabel: undefined,
    };
  }

  const elapsedSec = (nowMs - new Date(startedAt).getTime()) / 1000;

  if (elapsedSec < minElapsedSec) {
    return {
      percentPerMin: undefined,
      etaSeconds: undefined,
      etaLabel: undefined,
    };
  }


  const percentPerMin = (progress / elapsedSec) * 60;
  const remaining = 100 - progress;
  const etaSeconds = remaining > 0 ? (remaining / progress) * elapsedSec : 0;

  return {
    percentPerMin,
    etaSeconds,
    etaLabel: remaining > 0 ? formatEta(etaSeconds, locale) : undefined,
  };
}
