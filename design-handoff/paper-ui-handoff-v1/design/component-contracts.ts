/** UI-only semantic examples. Map existing domain models; DO NOT introduce a new backend schema. */
export type RoleId = 'translator' | 'proofreader' | 'linguist' | 'editor';
export type QualityId = 'speed' | 'precise' | 'deep' | 'refined';
export type ProcessingState =
  | 'ready' | 'importing' | 'recognizing' | 'queued' | 'running' | 'retrying'
  | 'pausing' | 'paused' | 'insufficientCredits' | 'needsReview' | 'failed' | 'complete';
export interface RoleStateView {
  id: RoleId;
  state: 'pending' | 'working' | 'done' | 'paused' | 'failed';
}
export interface BookRowView {
  id: string; title: string; coverUri?: string; sourceLanguage?: string; targetLanguage: string;
  kind: string; quality: QualityId; state: ProcessingState;
  completedChapters: number; totalChapters?: number;
  /** Authority: existing service only. Undefined means don't show a made-up percentage. */
  progressFraction?: number;
  currentChapter?: number; stageLabel?: string; pauseReason?: string;
  canReadCompleted: boolean; canReadStreamingDraft: boolean;
  canPause: boolean; canResume: boolean; canExport: boolean; canPublish: boolean;
  sourceTextAvailable: boolean; isPurchasedTranslation: boolean;
}
export interface NameRowView {
  bookId: string; termId: string; source: string; target: string;
  /** Context and alias metadata may remain in the existing domain layer; not an editing workflow. */
  context?: { locationLabel: string; text: string };
}
export interface UiActions {
  openBook(bookId: string, mode: 'completed' | 'streamingDraft'): void;
  openProgress(bookId: string): void;
  requestPause(bookId: string): Promise<void>;
  requestResume(bookId: string): Promise<void>;
  /** Writes a scoped preference through the existing service. No LLM, retranslation or charging. */
  saveNameOverride(bookId: string, termId: string, target: string): Promise<void>;
  /** Keep actual export formats, permissions and errors. */
  openExistingExport(bookId: string): void;
}
// Not provided here: model calls, queue orchestration, payments, OCR, migrations, persistent stores.
