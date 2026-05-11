import { test, expect, type APIRequestContext } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';

const API = 'http://localhost:3001';
const REPO_ROOT = path.resolve(__dirname, '../..');
const TEST_FILE = process.env.SIDEKICK_AB_TEST_FILE
  ? path.resolve(REPO_ROOT, process.env.SIDEKICK_AB_TEST_FILE)
  : path.join(REPO_ROOT, 'test-files', 'sidekick-test.pdf');
const OUTPUT_ROOT = path.join(REPO_ROOT, 'test-files', 'sidekick-test');
const SOURCE_LANG = process.env.SIDEKICK_AB_SOURCE_LANG ?? 'en';
const TARGET_LANG = process.env.SIDEKICK_AB_TARGET_LANG ?? 'zh';
const POLISH_STYLE =
  process.env.SIDEKICK_AB_POLISH_STYLE ??
  '中文自然、准确、流畅，保留原文的悬疑感和叙事节奏；不要添加原文没有的信息。';

const PRIMARY_55 = process.env.SIDEKICK_MATRIX_GPT55_MODEL ?? 'gpt-5.5';
const PRIMARY_54 = process.env.SIDEKICK_MATRIX_GPT54_MODEL ?? 'gpt-5.4';
const REVIEW_MINI = process.env.SIDEKICK_MATRIX_GPT54_MINI_MODEL ?? 'gpt-5.4-mini';

type SettingsMap = Record<string, string>;

type ScoreName =
  | 'accuracy'
  | 'completeness'
  | 'terminology'
  | 'formatting'
  | 'readability'
  | 'style_control';

interface Book {
  id: string;
  title: string;
}

interface Chapter {
  id: string;
  status: string;
  translationProgress?: number;
  tokensPerSecond?: number | null;
  _count?: { pages: number };
}

interface PageRecord {
  id: string;
  pageNumber: number;
  sourceText: string | null;
  targetText: string | null;
  translationStatus: string;
  errorMessage?: string | null;
}

interface VariantConfig {
  id: string;
  label: string;
  primaryModel: string;
  sidekickModel: string;
  glossaryEnabled: boolean;
  proofreadEnabled: boolean;
  polishEnabled: boolean;
  description: string;
}

interface VariantResult {
  config: VariantConfig;
  book: Book;
  chapter: { id: string };
  pages: PageRecord[];
  durationMs: number;
  sourceText: string;
  targetText: string;
  metrics: VariantMetrics;
}

interface VariantMetrics {
  pageCount: number;
  completedPages: number;
  failedPages: number;
  sourceChars: number;
  targetChars: number;
  estimatedInputTokens: number;
  estimatedOutputTokens: number;
  estimatedTotalTokens: number;
  charsPerSecond: number;
  estimatedTokensPerSecond: number;
  allowedResidualTerms: string[];
  suspiciousResidualTerms: string[];
  protectedMarkerCount: number;
  missingProtectedMarkerCount: number;
}

const VARIANTS: VariantConfig[] = [
  {
    id: 'A-gpt-5-5-self-glossary',
    label: 'GPT-5.5 + self glossary',
    primaryModel: PRIMARY_55,
    sidekickModel: PRIMARY_55,
    glossaryEnabled: true,
    proofreadEnabled: false,
    polishEnabled: false,
    description: 'Primary GPT-5.5 translation; sidekick only extracts advanced glossary using the same model.',
  },
  {
    id: 'B-gpt-5-4-self-glossary',
    label: 'GPT-5.4 + self glossary',
    primaryModel: PRIMARY_54,
    sidekickModel: PRIMARY_54,
    glossaryEnabled: true,
    proofreadEnabled: false,
    polishEnabled: false,
    description: 'Primary GPT-5.4 translation; sidekick only extracts advanced glossary using the same model.',
  },
  {
    id: 'C-gpt-5-4-self-review',
    label: 'GPT-5.4 + GPT-5.4 review',
    primaryModel: PRIMARY_54,
    sidekickModel: PRIMARY_54,
    glossaryEnabled: true,
    proofreadEnabled: true,
    polishEnabled: false,
    description: 'Primary GPT-5.4 translation; same model performs advanced glossary and conservative review.',
  },
  {
    id: 'D-gpt-5-4-mini-review',
    label: 'GPT-5.4 + GPT-5.4-mini review',
    primaryModel: PRIMARY_54,
    sidekickModel: REVIEW_MINI,
    glossaryEnabled: true,
    proofreadEnabled: true,
    polishEnabled: false,
    description: 'Primary GPT-5.4 translation; GPT-5.4-mini performs advanced glossary and conservative review.',
  },
];

function runId() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function queryRawSettings(): SettingsMap {
  const sql = [
    'select key || E\'\\t\' || value',
    'from "Settings"',
    'where key in (',
    "'llm.baseUrl','llm.apiKey','llm.model','llm.temperature','llm.topP','llm.timeoutMs',",
    "'sidekick.enabled','sidekick.baseUrl','sidekick.apiKey','sidekick.model',",
    "'sidekick.proofreadEnabled','sidekick.polishEnabled','sidekick.glossaryEnabled',",
    "'translation.stylePrompt','translation.reasoningEffort','translation.concurrency'",
    ')',
    'order by key;',
  ].join(' ');
  const raw = execFileSync(
    'docker',
    ['compose', 'exec', '-T', 'postgres', 'psql', '-U', 'bookllm', '-d', 'bookllm', '-tA', '-c', sql],
    { cwd: REPO_ROOT, encoding: 'utf8' },
  );
  return Object.fromEntries(
    raw
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        const tab = line.indexOf('\t');
        return [line.slice(0, tab), line.slice(tab + 1)];
      }),
  );
}

async function saveLlm(request: APIRequestContext, patch: Record<string, unknown>) {
  const res = await request.put(`${API}/settings/llm`, { data: patch });
  expect(res.status()).toBeLessThan(400);
}

async function saveSidekick(request: APIRequestContext, patch: Record<string, unknown>) {
  const res = await request.put(`${API}/settings/sidekick`, { data: patch });
  expect(res.status()).toBeLessThan(400);
}

async function saveTranslation(request: APIRequestContext, patch: Record<string, unknown>) {
  const res = await request.put(`${API}/settings/translation`, { data: patch });
  expect(res.status()).toBeLessThan(400);
}

async function createBook(request: APIRequestContext, title: string): Promise<Book> {
  const res = await request.post(`${API}/books`, {
    data: { title, sourceLang: SOURCE_LANG, targetLang: TARGET_LANG },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<Book>;
}

async function createChapter(request: APIRequestContext, bookId: string): Promise<{ id: string }> {
  const res = await request.post(`${API}/chapters`, {
    data: { bookId, chapterNumber: 1, title: 'Sidekick Matrix Test' },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<{ id: string }>;
}

async function uploadDocument(request: APIRequestContext, bookId: string, chapterId: string) {
  const ext = path.extname(TEST_FILE).toLowerCase();
  const isEpub = ext === '.epub';
  const endpoint = isEpub ? 'epub' : 'pdf';
  const mimeType = isEpub ? 'application/epub+zip' : 'application/pdf';
  const res = await request.post(`${API}/pages/upload/${endpoint}`, {
    multipart: {
      file: { name: path.basename(TEST_FILE), mimeType, buffer: fs.readFileSync(TEST_FILE) },
      bookId,
      chapterId,
      language: SOURCE_LANG,
    },
  });
  expect(res.status()).toBe(201);
}

async function startTranslation(request: APIRequestContext, bookId: string) {
  const res = await request.post(`${API}/chapters/book/${bookId}/translate`);
  expect(res.status()).toBe(202);
  return res.json() as Promise<{ enqueuedPages: number }>;
}

async function getBookPages(request: APIRequestContext, bookId: string): Promise<PageRecord[]> {
  const res = await request.get(`${API}/pages/book/${bookId}`);
  expect(res.status()).toBe(200);
  return res.json() as Promise<PageRecord[]>;
}

async function getBookChapters(request: APIRequestContext, bookId: string): Promise<Chapter[]> {
  const res = await request.get(`${API}/chapters/book/${bookId}`);
  expect(res.status()).toBe(200);
  return res.json() as Promise<Chapter[]>;
}

async function waitForTranslation(request: APIRequestContext, bookId: string, timeoutMs = 45 * 60_000) {
  const deadline = Date.now() + timeoutMs;
  let lastPages: PageRecord[] = [];
  while (Date.now() < deadline) {
    lastPages = await getBookPages(request, bookId);
    const chapters = await getBookChapters(request, bookId);
    const done =
      lastPages.length > 0 &&
      lastPages.every((p) => ['completed', 'failed'].includes(p.translationStatus)) &&
      chapters.every((c) => ['completed', 'failed'].includes(c.status));
    if (done) {
      const failed = lastPages.filter((p) => p.translationStatus === 'failed');
      expect(failed, `failed pages: ${JSON.stringify(failed)}`).toHaveLength(0);
      return lastPages.sort((a, b) => a.pageNumber - b.pageNumber);
    }
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  throw new Error(`Timed out waiting for translation. Last pages: ${JSON.stringify(lastPages)}`);
}

function joinSource(pages: PageRecord[]) {
  return pages.map((p) => `[Page ${p.pageNumber}]\n${p.sourceText ?? ''}`).join('\n\n');
}

function joinTarget(pages: PageRecord[]) {
  return pages.map((p) => `[Page ${p.pageNumber}]\n${p.targetText ?? ''}`).join('\n\n');
}

function estimateTokens(text: string): number {
  let tokens = 0;
  for (const char of text) {
    if (/[-A-Za-z0-9]/.test(char)) tokens += 0.25;
    else if (/\s/.test(char)) tokens += 0;
    else if (/[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]/.test(char)) tokens += 1;
    else tokens += 0.5;
  }
  return Math.max(1, Math.ceil(tokens));
}

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function protectedMarkers(text: string): string[] {
  return text.match(/\[\[OB_IMAGE:[^\]]+\]\]/g) ?? [];
}

function classifyResidualTerms(
  sourceText: string,
  targetText: string,
): { allowed: string[]; suspicious: string[] } {
  const allow = new Set([
    'page', 'ob', 'image', 'html', 'http', 'https', 'www', 'isbn', 'usa', 'nato', 'gmbh', 'llc',
    'thomas', 'pynchon', 'gravity', 'rainbow', 'london', 'germany', 'france', 'english', 'chinese',
  ]);

  const sourceWordRaw = sourceText.match(/\b[A-Za-z][A-Za-z'-]{2,}\b/g) ?? [];
  const sourceTerms = new Set<string>();
  const likelyProper = new Set<string>();

  for (const raw of sourceWordRaw) {
    const term = raw.toLowerCase().replace(/^'+|'+$/g, '');
    if (term.length < 4 || allow.has(term)) continue;
    sourceTerms.add(term);
    if (/^[A-Z][a-z]+(?:'[A-Za-z]+)?$/.test(raw) || /^[A-Z]{2,}$/.test(raw)) {
      likelyProper.add(term);
    }
  }

  const targetTerms =
    (targetText.toLowerCase().match(/\b[a-z][a-z'-]{3,}\b/g) ?? [])
      .map((term) => term.replace(/^'+|'+$/g, ''))
      .filter((term) => term.length >= 4 && !allow.has(term));

  const allowed: string[] = [];
  const suspicious: string[] = [];
  for (const term of targetTerms) {
    if (!sourceTerms.has(term)) continue;
    if (likelyProper.has(term)) {
      allowed.push(term);
    } else {
      suspicious.push(term);
    }
  }

  return {
    allowed: [...new Set(allowed)].slice(0, 80),
    suspicious: [...new Set(suspicious)].slice(0, 80),
  };
}

function computeMetrics(pages: PageRecord[], sourceText: string, targetText: string, durationMs: number): VariantMetrics {
  const sourceMarkers = protectedMarkers(sourceText);
  const targetMarkers = protectedMarkers(targetText);
  const missingMarkers = sourceMarkers.filter((marker) => !targetMarkers.includes(marker));
  const residuals = classifyResidualTerms(sourceText, targetText);
  const estimatedInputTokens = estimateTokens(sourceText);
  const estimatedOutputTokens = estimateTokens(targetText);
  return {
    pageCount: pages.length,
    completedPages: pages.filter((p) => p.translationStatus === 'completed').length,
    failedPages: pages.filter((p) => p.translationStatus === 'failed').length,
    sourceChars: sourceText.length,
    targetChars: targetText.length,
    estimatedInputTokens,
    estimatedOutputTokens,
    estimatedTotalTokens: estimatedInputTokens + estimatedOutputTokens,
    charsPerSecond: Math.round((targetText.length / Math.max(durationMs / 1000, 1)) * 10) / 10,
    estimatedTokensPerSecond: Math.round((estimatedOutputTokens / Math.max(durationMs / 1000, 1)) * 10) / 10,
    allowedResidualTerms: residuals.allowed,
    suspiciousResidualTerms: residuals.suspicious,
    protectedMarkerCount: targetMarkers.length,
    missingProtectedMarkerCount: missingMarkers.length,
  };
}

function scoreVariant(result: VariantResult): Record<ScoreName, number> & { total: number } {
  const residualPenalty = Math.min(20, result.metrics.suspiciousResidualTerms.length * 2);
  const markerPenalty = Math.min(15, result.metrics.missingProtectedMarkerCount * 5);
  const failurePenalty = result.metrics.failedPages > 0 ? 25 : 0;
  const lengthRatio = result.metrics.targetChars / Math.max(result.metrics.sourceChars, 1);
  const lengthPenalty = lengthRatio < 0.18 || lengthRatio > 0.65 ? 8 : lengthRatio < 0.25 ? 3 : 0;
  const reviewBonus = result.config.proofreadEnabled ? 2 : 0;
  const glossaryBonus = result.config.glossaryEnabled ? 2 : 0;
  const scores = {
    accuracy: Math.max(0, 30 - residualPenalty - failurePenalty),
    completeness: Math.max(0, 15 - lengthPenalty - failurePenalty),
    terminology: Math.max(0, 15 - Math.min(8, residualPenalty / 2) + glossaryBonus),
    formatting: Math.max(0, 15 - markerPenalty),
    readability: Math.max(0, 15 + reviewBonus - Math.min(6, residualPenalty / 4)),
    style_control: Math.max(0, 10 - (result.config.polishEnabled ? 2 : 0)),
  };
  return { ...scores, total: Math.round(Object.values(scores).reduce((sum, value) => sum + value, 0)) };
}

function extractPageSnippet(text: string, pageNumber: number, maxChars = 1400): string {
  const marker = `[Page ${pageNumber}]`;
  const start = text.indexOf(marker);
  if (start === -1) return text.slice(0, maxChars);
  const next = text.indexOf('[Page ', start + marker.length);
  return text.slice(start, next === -1 ? undefined : next).slice(0, maxChars);
}

function writeVisualReport(outputDir: string, results: VariantResult[], metadata: Record<string, unknown>) {
  const scores = Object.fromEntries(results.map((result) => [result.config.id, scoreVariant(result)]));
  const best = [...results].sort((a, b) => scores[b.config.id].total - scores[a.config.id].total)[0];
  const summaryRows = results
    .map((result) => {
      const score = scores[result.config.id];
      return `<tr>
        <td><strong>${escapeHtml(result.config.label)}</strong><span>${escapeHtml(result.config.description)}</span></td>
        <td>${score.total}</td>
        <td>${result.metrics.completedPages}/${result.metrics.pageCount}</td>
        <td>${Math.round(result.durationMs / 1000)}s</td>
        <td>${result.metrics.estimatedInputTokens.toLocaleString()} / ${result.metrics.estimatedOutputTokens.toLocaleString()}</td>
        <td>${result.metrics.estimatedTokensPerSecond}</td>
        <td>${result.metrics.suspiciousResidualTerms.length ? escapeHtml(result.metrics.suspiciousResidualTerms.slice(0, 12).join(', ')) : 'None found'}<span>allowed: ${result.metrics.allowedResidualTerms.slice(0, 8).join(', ') || 'none'}</span></td>
      </tr>`;
    })
    .join('\n');
  const scoreCards = results
    .map((result) => {
      const score = scores[result.config.id];
      const bars = (['accuracy', 'completeness', 'terminology', 'formatting', 'readability', 'style_control'] as ScoreName[])
        .map((name) => {
          const max = name === 'accuracy' ? 30 : name === 'style_control' ? 10 : 15;
          const pct = Math.round((score[name] / max) * 100);
          return `<div class="bar-row"><span>${name}</span><div class="bar"><i style="width:${pct}%"></i></div><b>${score[name]}/${max}</b></div>`;
        })
        .join('');
      return `<section class="score-card">
        <div class="score-head"><h3>${escapeHtml(result.config.label)}</h3><strong>${score.total}</strong></div>
        ${bars}
      </section>`;
    })
    .join('\n');
  const snippets = [1, 2, 3]
    .map((pageNo) => {
      const columns = results
        .map(
          (result) => `<div class="snippet"><h4>${escapeHtml(result.config.label)}</h4><pre>${escapeHtml(extractPageSnippet(result.targetText, pageNo))}</pre></div>`,
        )
        .join('');
      return `<section class="page-compare"><h3>Page ${pageNo} comparison</h3><div class="snippet-grid"><div class="snippet source"><h4>Source</h4><pre>${escapeHtml(extractPageSnippet(results[0].sourceText, pageNo))}</pre></div>${columns}</div></section>`;
    })
    .join('\n');
  const jsonScript = escapeHtml(JSON.stringify({ metadata, scores, results: results.map((r) => ({ config: r.config, metrics: r.metrics, bookId: r.book.id })) }, null, 2));

  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BookLLM Sidekick Matrix Report</title>
  <style>
    :root { color-scheme: light; --ink:#101828; --muted:#667085; --line:#e4e7ec; --blue:#2563eb; --green:#079455; --paper:#fbfcff; --card:#ffffff; }
    body { margin:0; font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color:var(--ink); background:linear-gradient(180deg,#f8fbff 0,#ffffff 34%,#f8fafc 100%); }
    .wrap { max-width: 1220px; margin: 0 auto; padding: 44px 28px 80px; }
    header { padding: 34px; border:1px solid var(--line); border-radius:28px; background:rgba(255,255,255,.88); box-shadow:0 24px 80px rgba(15,23,42,.08); }
    .eyebrow { color:var(--blue); font-weight:800; text-transform:uppercase; letter-spacing:.12em; font-size:12px; }
    h1 { margin:10px 0 12px; font-size:42px; line-height:1.05; letter-spacing:-.04em; }
    .lead { max-width:850px; color:var(--muted); font-size:17px; line-height:1.7; }
    .verdict { display:flex; gap:18px; flex-wrap:wrap; margin-top:22px; }
    .pill { border:1px solid var(--line); background:#fff; border-radius:999px; padding:10px 14px; box-shadow:0 10px 30px rgba(15,23,42,.06); }
    .pill b { color:var(--green); }
    table { width:100%; border-collapse:collapse; margin:28px 0; background:var(--card); border:1px solid var(--line); border-radius:22px; overflow:hidden; box-shadow:0 18px 55px rgba(15,23,42,.06); }
    th,td { padding:16px 18px; text-align:left; border-bottom:1px solid var(--line); vertical-align:top; }
    th { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; background:#f8fafc; }
    td span { display:block; margin-top:5px; color:var(--muted); font-size:13px; line-height:1.5; }
    .scores { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:18px; }
    .score-card { background:#fff; border:1px solid var(--line); border-radius:22px; padding:20px; box-shadow:0 14px 45px rgba(15,23,42,.05); }
    .score-head { display:flex; align-items:center; justify-content:space-between; gap:20px; }
    .score-head h3 { margin:0; font-size:18px; }
    .score-head strong { font-size:36px; color:var(--blue); }
    .bar-row { display:grid; grid-template-columns:120px 1fr 60px; gap:12px; align-items:center; margin-top:12px; font-size:13px; color:var(--muted); }
    .bar { height:9px; background:#eef2ff; border-radius:999px; overflow:hidden; }
    .bar i { display:block; height:100%; background:linear-gradient(90deg,#2563eb,#22c55e); border-radius:999px; }
    .page-compare { margin-top:28px; }
    .page-compare h3 { font-size:22px; margin:0 0 14px; }
    .snippet-grid { display:grid; grid-template-columns:repeat(5,minmax(260px,1fr)); gap:14px; overflow-x:auto; padding-bottom:10px; }
    .snippet { min-width:260px; background:#fff; border:1px solid var(--line); border-radius:18px; overflow:hidden; }
    .snippet h4 { margin:0; padding:12px 14px; background:#f8fafc; border-bottom:1px solid var(--line); font-size:13px; }
    .snippet pre { margin:0; padding:14px; white-space:pre-wrap; font-family: ui-serif, Georgia, serif; font-size:14px; line-height:1.75; max-height:420px; overflow:auto; }
    .source { background:#fffcf5; }
    details { margin-top:30px; background:#0b1020; color:#e2e8f0; border-radius:18px; padding:18px; }
    details pre { overflow:auto; font-size:12px; line-height:1.6; }
    @media (max-width: 820px) { h1 { font-size:32px; } .scores { grid-template-columns:1fr; } .wrap { padding:24px 16px 56px; } }
  </style>
</head>
<body>
  <main class="wrap">
    <header>
      <div class="eyebrow">BookLLM Sidekick Matrix</div>
      <h1>Gravity's Rainbow, first 10 pages</h1>
      <p class="lead">Four model strategies were translated independently with advanced glossary enabled in every run. Polish/rewrite stayed disabled. Scores below are automatic heuristics for triage; final judgment should be made by reading the snippets and full text.</p>
      <div class="verdict">
        <div class="pill">Auto-best by heuristic: <b>${escapeHtml(best.config.label)}</b></div>
        <div class="pill">Source: <b>${escapeHtml(path.relative(REPO_ROOT, TEST_FILE))}</b></div>
        <div class="pill">Target: <b>${escapeHtml(TARGET_LANG)}</b></div>
      </div>
    </header>
    <table>
      <thead><tr><th>Variant</th><th>Score</th><th>Pages</th><th>Time</th><th>Est. in/out tokens</th><th>tok/s</th><th>Suspicious residual terms</th></tr></thead>
      <tbody>${summaryRows}</tbody>
    </table>
    <section class="scores">${scoreCards}</section>
    ${snippets}
    <details><summary>Raw matrix JSON</summary><pre>${jsonScript}</pre></details>
  </main>
</body>
</html>`;

  fs.writeFileSync(path.join(outputDir, 'visual-report.html'), html);
  fs.writeFileSync(
    path.join(outputDir, 'visual-summary.md'),
    [
      '# Sidekick Matrix Visual Summary',
      '',
      `- Source: \`${path.relative(REPO_ROOT, TEST_FILE)}\``,
      `- Auto-best by heuristic: **${best.config.label}**`,
      `- Note: final judgment is manual; heuristic scores mainly flag residual source terms, marker loss, failed pages, and rough length anomalies.`,
      '',
      '| Variant | Score | Pages | Time | Est. input | Est. output | Suspicious residual terms | Allowed residual terms |',
      '|---|---:|---:|---:|---:|---:|---|---|',
      ...results.map((result) => {
        const score = scores[result.config.id];
        return `| ${result.config.label} | ${score.total} | ${result.metrics.completedPages}/${result.metrics.pageCount} | ${Math.round(result.durationMs / 1000)}s | ${result.metrics.estimatedInputTokens} | ${result.metrics.estimatedOutputTokens} | ${result.metrics.suspiciousResidualTerms.slice(0, 12).join(', ') || 'None found'} | ${result.metrics.allowedResidualTerms.slice(0, 12).join(', ') || 'None found'} |`;
      }),
    ].join('\n'),
  );
}

async function configureVariant(request: APIRequestContext, rawSettings: SettingsMap, config: VariantConfig) {
  await saveLlm(request, {
    baseUrl: rawSettings['llm.baseUrl'],
    apiKey: rawSettings['llm.apiKey'] || 'local-dev-key',
    model: config.primaryModel,
    temperature: Number(rawSettings['llm.temperature'] ?? 0.2),
    topP: Number(rawSettings['llm.topP'] ?? 1),
    timeoutMs: Number(rawSettings['llm.timeoutMs'] ?? 60000),
  });
  await saveSidekick(request, {
    enabled: true,
    baseUrl: rawSettings['llm.baseUrl'],
    apiKey: rawSettings['llm.apiKey'] || 'local-dev-key',
    model: config.sidekickModel,
    proofreadEnabled: config.proofreadEnabled,
    polishEnabled: config.polishEnabled,
    glossaryEnabled: config.glossaryEnabled,
  });
}

async function restoreSettings(request: APIRequestContext, rawSettings: SettingsMap) {
  await saveLlm(request, {
    baseUrl: rawSettings['llm.baseUrl'],
    apiKey: rawSettings['llm.apiKey'] || 'local-dev-key',
    model: rawSettings['llm.model'],
    temperature: Number(rawSettings['llm.temperature'] ?? 0.2),
    topP: Number(rawSettings['llm.topP'] ?? 1),
    timeoutMs: Number(rawSettings['llm.timeoutMs'] ?? 60000),
  });
  await saveSidekick(request, {
    enabled: rawSettings['sidekick.enabled'] === 'true',
    baseUrl: rawSettings['sidekick.baseUrl'] ?? '',
    apiKey: rawSettings['sidekick.apiKey'] ?? '',
    model: rawSettings['sidekick.model'] ?? '',
    proofreadEnabled: rawSettings['sidekick.proofreadEnabled'] === 'true',
    polishEnabled: rawSettings['sidekick.polishEnabled'] === 'true',
    glossaryEnabled: rawSettings['sidekick.glossaryEnabled'] === 'true',
  });
  await saveTranslation(request, {
    stylePrompt: rawSettings['translation.stylePrompt'] ?? '',
  });
}

async function runVariant(request: APIRequestContext, rawSettings: SettingsMap, config: VariantConfig): Promise<VariantResult> {
  await configureVariant(request, rawSettings, config);
  const book = await createBook(request, `Sidekick-Matrix-${config.id}-${Date.now()}`);
  const chapter = await createChapter(request, book.id);
  await uploadDocument(request, book.id, chapter.id);
  const pagesAfterUpload = await getBookPages(request, book.id);
  expect(pagesAfterUpload.length).toBeGreaterThan(0);

  const startedAt = Date.now();
  const { enqueuedPages } = await startTranslation(request, book.id);
  expect(enqueuedPages).toBeGreaterThan(0);
  const translatedPages = await waitForTranslation(request, book.id);
  const durationMs = Date.now() - startedAt;
  const sourceText = joinSource(translatedPages);
  const targetText = joinTarget(translatedPages);
  const metrics = computeMetrics(translatedPages, sourceText, targetText, durationMs);
  return { config, book, chapter, pages: translatedPages, durationMs, sourceText, targetText, metrics };
}

test.describe('Sidekick matrix real translation QA', () => {
  test.setTimeout(120 * 60_000);

  test('translates Gravity\'s Rainbow matrix with self glossary and review-only variants', async ({ request }) => {
    test.skip(!fs.existsSync(TEST_FILE), `Missing ${TEST_FILE}`);
    fs.mkdirSync(OUTPUT_ROOT, { recursive: true });
    const outputDir = path.join(OUTPUT_ROOT, `run-${runId()}`);
    fs.mkdirSync(outputDir, { recursive: true });

    const rawSettings = queryRawSettings();
    expect(rawSettings['llm.model'], 'primary model must be configured').toBeTruthy();
    expect(rawSettings['llm.baseUrl'], 'primary baseUrl must be configured').toBeTruthy();

    const results: VariantResult[] = [];
    try {
      await saveTranslation(request, { stylePrompt: POLISH_STYLE });
      for (const variant of VARIANTS) {
        const result = await runVariant(request, rawSettings, variant);
        results.push(result);
        fs.writeFileSync(path.join(outputDir, `${variant.id}.zh.txt`), result.targetText);
      }

      const sourceText = results[0]?.sourceText ?? '';
      fs.writeFileSync(path.join(outputDir, 'source.txt'), sourceText);
      const metadata = {
        sourceFile: TEST_FILE,
        sourceLang: SOURCE_LANG,
        targetLang: TARGET_LANG,
        polishStyle: POLISH_STYLE,
        originalPrimaryModel: rawSettings['llm.model'],
        variants: results.map((result) => ({
          id: result.config.id,
          label: result.config.label,
          primaryModel: result.config.primaryModel,
          sidekickModel: result.config.sidekickModel,
          glossaryEnabled: result.config.glossaryEnabled,
          proofreadEnabled: result.config.proofreadEnabled,
          polishEnabled: result.config.polishEnabled,
          bookId: result.book.id,
          durationMs: result.durationMs,
          metrics: result.metrics,
        })),
      };
      fs.writeFileSync(path.join(outputDir, 'matrix-results.json'), JSON.stringify(metadata, null, 2));
      fs.writeFileSync(path.join(outputDir, 'metadata.json'), JSON.stringify(metadata, null, 2));
      writeVisualReport(outputDir, results, metadata);
      fs.writeFileSync(path.join(OUTPUT_ROOT, 'latest-run.txt'), path.relative(OUTPUT_ROOT, outputDir));

      expect(results).toHaveLength(VARIANTS.length);
      for (const result of results) {
        expect(result.metrics.failedPages, `${result.config.label} failed pages`).toBe(0);
        expect(result.targetText.length, `${result.config.label} empty target`).toBeGreaterThan(0);
      }
    } finally {
      await restoreSettings(request, rawSettings);
    }
  });
});
