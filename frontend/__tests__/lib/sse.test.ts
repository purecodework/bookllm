import { parseSseJson } from '@/lib/sse';

describe('parseSseJson', () => {
  it('parses normal SSE JSON payloads', () => {
    expect(parseSseJson<{ type: string }>('{"type":"page_token"}')).toEqual({
      type: 'page_token',
    });
  });

  it('parses legacy double-encoded SSE payloads', () => {
    expect(parseSseJson<{ type: string }>(JSON.stringify('{"type":"page_token"}'))).toEqual({
      type: 'page_token',
    });
  });

  it('returns null for malformed payloads', () => {
    expect(parseSseJson('{bad')).toBeNull();
  });
});
