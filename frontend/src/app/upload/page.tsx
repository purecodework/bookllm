"use client";

import { useState, useCallback, useRef } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import {
  Upload,
  FileText,
  File,
  BookOpen,
  X,
  CheckCircle2,
  AlertCircle,
  Loader2,
  ArrowLeft,
} from "lucide-react";
import { AppShell } from "@/components/layout/app-shell";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { cn, formatFileSize } from "@/lib/utils";
import { useI18n } from "@/lib/i18n";
import {
  createBook,
  createChapter,
  uploadPdf,
  uploadTxt,
  uploadEpub,
} from "@/lib/api";

const ACCEPT_TYPES: Record<
  string,
  { label: string; icon: typeof FileText; color: string }
> = {
  "text/plain": { label: "TXT", icon: FileText, color: "#a3a3a3" },
  "application/pdf": { label: "PDF", icon: FileText, color: "#ef4444" },
  "application/epub+zip": { label: "EPUB", icon: BookOpen, color: "#8b5cf6" },
};

const ACCEPTED_MIME_TYPES = new Set(Object.keys(ACCEPT_TYPES));

type UploadStage = "idle" | "creating-book" | "uploading" | "done" | "error";

export default function UploadPage() {
  const { t, languageName } = useI18n();
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [file, setFile] = useState<File | null>(null);
  const [isDragging, setIsDragging] = useState(false);
  const [bookTitle, setBookTitle] = useState("");
  const [sourceLang, setSourceLang] = useState("auto");
  const [targetLang, setTargetLang] = useState("zh");
  const [scannedPdfOcr, setScannedPdfOcr] = useState(false);

  const [stage, setStage] = useState<UploadStage>("idle");
  const [progress, setProgress] = useState(0);
  const [errorMsg, setErrorMsg] = useState("");
  const [createdBookId, setCreatedBookId] = useState<string | null>(null);
  const defaultChapterTitle = t("upload.defaultChapterTitle");
  const languages = [
    { value: "auto", label: t("upload.autoDetect") },
    { value: "zh", label: languageName("zh") },
    { value: "en", label: languageName("en") },
    { value: "ja", label: languageName("ja") },
    { value: "ko", label: languageName("ko") },
    { value: "fr", label: languageName("fr") },
    { value: "de", label: languageName("de") },
    { value: "es", label: languageName("es") },
    { value: "ru", label: languageName("ru") },
  ];

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(true);
  }, []);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
  }, []);

  const acceptFile = useCallback((f: File) => {
    const mime = f.type;

    const isEpub = mime === "application/epub+zip" || f.name.toLowerCase().endsWith(".epub");
    const resolvedMime = isEpub ? "application/epub+zip" : mime;
    if (!ACCEPTED_MIME_TYPES.has(resolvedMime)) {
      setErrorMsg(t("upload.unsupportedType"));
      setStage("error");
      return;
    }
    setErrorMsg("");
    setStage("idle");
    setFile(f);
    setBookTitle(f.name.replace(/\.[^.]+$/, ""));
  }, [t]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    const f = e.dataTransfer.files[0];
    if (f) acceptFile(f);
  }, [acceptFile]);

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (f) acceptFile(f);
  };

  const handleUpload = async () => {
    if (!file) return;
    setErrorMsg("");
    if (file.size > 200 * 1024 * 1024) {
      setErrorMsg(t("upload.fileTooLarge"));
      return;
    }

    try {
      setStage("creating-book");
      setProgress(10);
      const book = await createBook({
        title: bookTitle || file.name,
        sourceLang,
        targetLang,
      });
      setCreatedBookId(book.id);
      setProgress(25);

      setStage("uploading");

      if (file.type === "application/epub+zip" || file.name.toLowerCase().endsWith(".epub")) {
        const chapter = await createChapter({
          bookId: book.id,
          chapterNumber: 1,
          title: bookTitle || defaultChapterTitle,
        });
        setProgress(40);
        await uploadEpub(file, book.id, chapter.id);
        setProgress(100);
      } else if (file.type === "text/plain") {
        const chapter = await createChapter({
          bookId: book.id,
          chapterNumber: 1,
          title: bookTitle || defaultChapterTitle,
        });
        setProgress(40);
        await uploadTxt(file, book.id, chapter.id);
        setProgress(100);
      } else {
        const chapter = await createChapter({
          bookId: book.id,
          chapterNumber: 1,
          title: bookTitle || defaultChapterTitle,
        });
        setProgress(40);
        await uploadPdf(
          file,
          book.id,
          chapter.id,
          sourceLang,
          file.type === "application/pdf" && scannedPdfOcr ? "force" : "auto",
        );
        setProgress(100);
      }

      setStage("done");
      setTimeout(() => router.push(`/book/${book.id}`), 1000);
    } catch (e) {
      setStage("error");
      setErrorMsg(e instanceof Error ? e.message : t("upload.errorRetry"));
    }
  };

  const reset = () => {
    setFile(null);
    setBookTitle("");
    setScannedPdfOcr(false);
    setStage("idle");
    setProgress(0);
    setErrorMsg("");
    setCreatedBookId(null);
  };

  const fileType = file ? ACCEPT_TYPES[file.type] : null;
  const FileIcon = fileType?.icon ?? File;
  const isUploading = stage === "creating-book" || stage === "uploading";

  const uploadingLabel =
    file?.type === "application/epub+zip"
      ? t("upload.stageParsingEpub")
      : file?.type === "text/plain"
        ? t("upload.stageParsingText")
        : t("upload.stageOcr");

  const stageLabel: Record<UploadStage, string> = {
    idle: "",
    "creating-book": t("upload.stageCreating"),
    uploading: uploadingLabel,
    done: t("upload.stageDone"),
    error: errorMsg,
  };

  return (
    <AppShell>
      <div className="mx-auto max-w-2xl p-4 md:p-8">
        <Link
          href="/"
          className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground transition-colors mb-6"
        >
          <ArrowLeft className="h-4 w-4" />
          {t("upload.backToLibrary")}
        </Link>

        <div className="mb-8">
          <h1 className="text-2xl font-semibold text-foreground tracking-tight">
            {t("upload.title")}
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            {t("upload.description")}
          </p>
        </div>

        <div className="space-y-6">
          {!file ? (
            <div
              onDragOver={handleDragOver}
              onDragLeave={handleDragLeave}
              onDrop={handleDrop}
              onClick={() => fileInputRef.current?.click()}
              className={cn(
                "flex flex-col items-center justify-center rounded-xl border-2 border-dashed p-16 text-center cursor-pointer transition-colors",
                isDragging
                  ? "border-primary bg-primary/5"
                  : "glass-panel border-border hover:border-primary/50",
              )}
            >
              <div
                className={cn(
                  "mb-4 h-16 w-16 rounded-2xl flex items-center justify-center transition-colors",
                  isDragging ? "bg-primary/20" : "bg-secondary",
                )}
              >
                <Upload
                  className={cn(
                    "h-8 w-8",
                    isDragging ? "text-primary" : "text-muted-foreground",
                  )}
                />
              </div>
              <p className="text-base font-medium text-foreground mb-1">
                {isDragging ? t("upload.dropToUpload") : t("upload.dragHere")}
              </p>
              <p className="text-sm text-muted-foreground mb-4">
                {t("common.or")}{" "}
                <span className="text-primary font-medium">
                  {t("upload.clickToChoose")}
                </span>
              </p>
              <div className="flex gap-2 flex-wrap justify-center">
                {["TXT", "PDF", "EPUB"].map((f) => (
                  <Badge key={f} variant="secondary" className="text-xs">
                    {f}
                  </Badge>
                ))}
              </div>
              <input
                ref={fileInputRef}
                type="file"
                accept=".txt,.pdf,.epub"
                className="hidden"
                onChange={handleFileSelect}
              />
            </div>
          ) : (
            <Card>
              <CardContent className="p-4">
                <div className="flex items-center gap-3">
                  <div
                    className="h-10 w-10 rounded-md flex items-center justify-center shrink-0"
                    style={{
                      backgroundColor: `${fileType?.color ?? "#71717a"}20`,
                    }}
                  >
                    <FileIcon
                      className="h-5 w-5"
                      style={{ color: fileType?.color ?? "#71717a" }}
                    />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-foreground truncate">
                      {file.name}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {formatFileSize(file.size)}
                    </p>
                  </div>
                  {stage === "idle" && (
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7 shrink-0"
                      onClick={reset}
                    >
                      <X className="h-3.5 w-3.5" />
                    </Button>
                  )}
                </div>
              </CardContent>
            </Card>
          )}

          {file && stage === "idle" && (
            <Card>
              <CardContent className="p-4 space-y-4">
                <h2 className="text-sm font-medium text-foreground">
                  {t("upload.projectSettings")}
                </h2>
                <div>
                  <label className="text-xs font-medium text-muted-foreground mb-1.5 block">
                    {t("upload.projectName")}
                  </label>
                  <Input
                    placeholder={t("upload.projectNamePlaceholder")}
                    value={bookTitle}
                    onChange={(e) => setBookTitle(e.target.value)}
                  />
                </div>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  {[
                    {
                      label: t("upload.sourceLanguage"),
                      value: sourceLang,
                      onChange: setSourceLang,
                      options: languages,
                    },
                    {
                      label: t("upload.targetLanguage"),
                      value: targetLang,
                      onChange: setTargetLang,
                      options: languages.filter((l) => l.value !== "auto"),
                    },
                  ].map(({ label, value, onChange, options }) => (
                    <div key={label}>
                      <label className="text-xs font-medium text-muted-foreground mb-1.5 block">
                        {label}
                      </label>
                      <select
                        className="glass-input flex h-9 w-full rounded-md border px-3 py-1 text-sm text-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                        value={value}
                        onChange={(e) => onChange(e.target.value)}
                      >
                        {options.map((o) => (
                          <option key={o.value} value={o.value}>
                            {o.label}
                          </option>
                        ))}
                      </select>
                    </div>
                  ))}
                </div>
                {file.type === "application/pdf" && (
                  <label className="flex items-start gap-3 rounded-lg border border-border bg-muted/30 p-3">
                    <input
                      type="checkbox"
                      checked={scannedPdfOcr}
                      onChange={(e) => setScannedPdfOcr(e.target.checked)}
                      className="mt-1 h-4 w-4 rounded border-border"
                    />
                    <span className="space-y-1">
                      <span className="block text-sm font-medium text-foreground">
                        {t("upload.scannedPdfOcr")}
                      </span>
                      <span className="block text-xs leading-relaxed text-muted-foreground">
                        {t("upload.scannedPdfOcrHelp")}
                      </span>
                    </span>
                  </label>
                )}
              </CardContent>
            </Card>
          )}

          {isUploading && (
            <Card>
              <CardContent className="p-4 space-y-3">
                <div className="flex items-center gap-2">
                  <Loader2 className="h-4 w-4 animate-spin text-primary shrink-0" />
                  <p className="text-sm text-foreground">{stageLabel[stage]}</p>
                </div>
                <Progress value={progress} className="h-1.5" />
              </CardContent>
            </Card>
          )}

          {stage === "done" && (
            <Card>
              <CardContent className="p-4">
                <div className="flex items-center gap-2">
                  <CheckCircle2 className="h-5 w-5 text-success shrink-0" />
                  <div>
                    <p className="text-sm font-medium text-foreground">
                      {t("upload.successRedirect")}
                    </p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {t("upload.translationQueued")}
                    </p>
                  </div>
                </div>
              </CardContent>
            </Card>
          )}

          {stage === "error" && (
            <Card className="border-destructive/50">
              <CardContent className="p-4">
                <div className="flex items-start gap-2">
                  <AlertCircle className="h-5 w-5 text-destructive shrink-0 mt-0.5" />
                  <div className="flex-1">
                    <p className="text-sm font-medium text-destructive">
                      {t("upload.failedTitle")}
                    </p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {errorMsg}
                    </p>
                    {createdBookId && (
                      <p className="text-xs text-muted-foreground mt-1">
                        {t("upload.createdPrefix", { id: createdBookId })}
                        <Link href="/" className="text-primary ml-1">
                          {t("upload.libraryLink")}
                        </Link>{" "}
                        {t("upload.viewSuffix")}
                      </p>
                    )}
                  </div>
                </div>
              </CardContent>
            </Card>
          )}

          {file && (
            <div className="flex justify-end gap-3">
              <Button variant="ghost" asChild>
                <Link href="/">{t("common.cancel")}</Link>
              </Button>
              {stage === "idle" && (
                <Button onClick={handleUpload} className="gap-2">
                  <Upload className="h-4 w-4" />
                  {t("upload.start")}
                </Button>
              )}
              {stage === "error" && (
                <Button onClick={reset} variant="outline">
                  {t("upload.chooseAgain")}
                </Button>
              )}
            </div>
          )}
        </div>
      </div>
    </AppShell>
  );
}
