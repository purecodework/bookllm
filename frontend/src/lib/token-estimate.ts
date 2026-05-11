export function estimateTokens(text: string): number {
  if (!text) return 0;
  const cjk = (text.match(/[\u3400-\u9fff]/g) ?? []).length;
  const latinNum = (text.match(/[A-Za-z0-9]/g) ?? []).length;
  const rest = Math.max(0, text.length - cjk - latinNum);


  const estimated = cjk + latinNum / 4 + rest / 2;
  return Math.max(0, Math.round(estimated));
}
