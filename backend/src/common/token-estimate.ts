import { get_encoding, type Tiktoken } from 'tiktoken';

let tokenizer: Tiktoken | null = null;

function getTokenizer(): Tiktoken {
  if (!tokenizer) tokenizer = get_encoding('cl100k_base');
  return tokenizer;
}


export function estimateTokens(text: string): number {
  if (!text.trim()) return 0;
  try {
    return Math.max(1, getTokenizer().encode(text).length);
  } catch {
    return Math.max(1, Math.ceil(text.length / 2));
  }
}
