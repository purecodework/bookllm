import { normalizeLlmProvider } from './llm.module';

describe('normalizeLlmProvider', () => {
  it('should keep known providers', () => {
    expect(normalizeLlmProvider('ollama')).toBe('ollama');
    expect(normalizeLlmProvider('lmstudio')).toBe('lmstudio');
    expect(normalizeLlmProvider('omlx')).toBe('omlx');
  });

  it('should fallback to openai-compatible for unknown provider', () => {
    expect(normalizeLlmProvider('something-else')).toBe('openai-compatible');
    expect(normalizeLlmProvider(undefined)).toBe('openai-compatible');
  });
});
