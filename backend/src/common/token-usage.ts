import type { PrismaService } from '../prisma/prisma.service';

export type UsageStage = 'glossary' | 'translation' | 'review' | 'polish';

export type UsageStageTotals = {
  inputTokens: number;
  outputTokens: number;
};

export type UsageByStage = Record<UsageStage, UsageStageTotals>;

export type UsageDelta = {
  inputTokens?: number;
  outputTokens?: number;
};

type UsagePrismaClient = Pick<PrismaService, 'book'>;

const STAGES: UsageStage[] = ['glossary', 'translation', 'review', 'polish'];

function normalizeTokenCount(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.round(n);
}

export function normalizeUsageByStage(value: unknown): Partial<UsageByStage> {
  if (!value || typeof value !== 'object') return {};
  const raw = value as Record<string, unknown>;
  const normalized: Partial<UsageByStage> = {};
  for (const stage of STAGES) {
    const current = raw[stage];
    if (!current || typeof current !== 'object') continue;
    const rec = current as Record<string, unknown>;
    normalized[stage] = {
      inputTokens: normalizeTokenCount(rec.inputTokens),
      outputTokens: normalizeTokenCount(rec.outputTokens),
    };
  }
  return normalized;
}

export async function persistBookUsageDelta(
  prisma: PrismaService,
  bookId: string,
  stage: UsageStage,
  delta: UsageDelta,
): Promise<void> {
  const inputTokens = normalizeTokenCount(delta.inputTokens);
  const outputTokens = normalizeTokenCount(delta.outputTokens);
  if (!inputTokens && !outputTokens) return;

  const persist = async (tx: UsagePrismaClient) => {
    const book = await tx.book.findUnique({
      where: { id: bookId },
      select: { usageByStage: true },
    });
    if (!book) return;

    const byStage = normalizeUsageByStage(book.usageByStage);
    const current = byStage[stage] ?? { inputTokens: 0, outputTokens: 0 };
    byStage[stage] = {
      inputTokens: current.inputTokens + inputTokens,
      outputTokens: current.outputTokens + outputTokens,
    };

    await tx.book.update({
      where: { id: bookId },
      data: {
        usageInputTokens: { increment: inputTokens },
        usageOutputTokens: { increment: outputTokens },
        usageByStage: byStage,
      },
    });
  };

  if (typeof prisma.$transaction === 'function') {
    await prisma.$transaction((tx) => persist(tx));
    return;
  }

  await persist(prisma);
}
