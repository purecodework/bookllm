import { computeEta, formatEta } from '@/lib/translation-eta';


const START = new Date('2026-01-01T00:00:00.000Z').toISOString();
const NOW_AT_120S = new Date('2026-01-01T00:02:00.000Z').getTime();

describe('formatEta', () => {
  it('秒数 < 60 只显示秒', () => {
    expect(formatEta(40)).toBe('≈ 40s');
  });

  it('整分钟不显示秒', () => {
    expect(formatEta(120)).toBe('≈ 2m');
  });

  it('有余秒时显示分和秒', () => {
    expect(formatEta(150)).toBe('≈ 2m 30s');
  });

  it('0 秒时返回 "≈ 0s"', () => {
    expect(formatEta(0)).toBe('≈ 0s');
  });

  it('大于 60 分钟时仍正确', () => {
    expect(formatEta(3660)).toBe('≈ 61m');
  });
});

describe('computeEta', () => {
  it('startedAt 为 null 时返回全 undefined', () => {
    const r = computeEta(50, null, NOW_AT_120S);
    expect(r.percentPerMin).toBeUndefined();
    expect(r.etaSeconds).toBeUndefined();
    expect(r.etaLabel).toBeUndefined();
  });

  it('progress 为 0 时返回全 undefined（避免除零）', () => {
    const r = computeEta(0, START, NOW_AT_120S);
    expect(r.percentPerMin).toBeUndefined();
  });

  it('elapsed 小于 minElapsedSec 时返回全 undefined', () => {
    const justStarted = new Date(NOW_AT_120S - 3000).toISOString();
    const r = computeEta(10, justStarted, NOW_AT_120S);
    expect(r.etaLabel).toBeUndefined();
  });

  it('正常情况：50% 进度 120s 后 → percentPerMin=25，etaSeconds=120', () => {


    const r = computeEta(50, START, NOW_AT_120S);
    expect(r.percentPerMin).toBeCloseTo(25, 5);
    expect(r.etaSeconds).toBeCloseTo(120, 5);
    expect(r.etaLabel).toBe('≈ 2m');
  });

  it('25% 进度 60s 后 → etaSeconds=180', () => {

    const nowAt60s = new Date('2026-01-01T00:01:00.000Z').getTime();
    const r = computeEta(25, START, nowAt60s);
    expect(r.etaSeconds).toBeCloseTo(180, 5);
    expect(r.etaLabel).toBe('≈ 3m');
  });

  it('progress=100 时 etaLabel 为 undefined（已完成）', () => {
    const r = computeEta(100, START, NOW_AT_120S);
    expect(r.etaLabel).toBeUndefined();
    expect(r.etaSeconds).toBe(0);
  });

  it('etaLabel 正确格式化为带余秒的字符串', () => {

    const nowAt30s = new Date('2026-01-01T00:00:30.000Z').getTime();
    const r = computeEta(10, START, nowAt30s);
    expect(r.etaLabel).toBe('≈ 4m 30s');
  });
});
