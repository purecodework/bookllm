"use client";

import { useEffect, useState, use } from "react";
import { Loader2 } from "lucide-react";
import { normalizeBlocks } from "@/lib/text-normalize";

function InlineMarkdown({ text }: { text: string }) {
  const parts = text.split(/(\*\*[^*]+\*\*|\*[^*]+\*)/g);
  return (
    <>
      {parts.map((part, i) => {
        if (part.startsWith("**") && part.endsWith("**"))
          return <strong key={i}>{part.slice(2, -2)}</strong>;
        if (part.startsWith("*") && part.endsWith("*"))
          return <em key={i}>{part.slice(1, -1)}</em>;
        return part;
      })}
    </>
  );
}
import { useI18n } from "@/lib/i18n";
import {
  fetchBook,
  fetchChaptersByBook,
  fetchPagesByChapter,
  type Book,
  type Page,
} from "@/lib/api";
import { getApiBase } from "@/lib/api-base";

export default function PrintPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { t } = useI18n();
  const { id: bookId } = use(params);
  const apiBase = getApiBase();
  const [book, setBook] = useState<Book | null>(null);
  const [pages, setPages] = useState<Page[]>([]);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    (async () => {
      const [b, chs] = await Promise.all([
        fetchBook(bookId),
        fetchChaptersByBook(bookId),
      ]);
      setBook(b);
      const allPages: Page[] = [];
      for (const ch of chs) {
        const ps = await fetchPagesByChapter(ch.id);
        allPages.push(
          ...ps.filter(
            (p) => p.translationStatus === "completed" && p.targetText,
          ),
        );
      }
      allPages.sort((a, b) => a.pageNumber - b.pageNumber);
      setPages(allPages);
      setReady(true);
    })();
  }, [bookId]);

  useEffect(() => {
    if (ready && pages.length > 0) {
      const timer = setTimeout(() => window.print(), 400);
      return () => clearTimeout(timer);
    }
  }, [ready, pages.length]);

  if (!ready) {
    return (
      <div className="flex items-center justify-center min-h-screen gap-3 text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin" />
        <span className="text-sm">{t("common.loading")}</span>
      </div>
    );
  }

  return (
    <>
      <div className="print:hidden fixed top-0 left-0 right-0 bg-muted border-b px-6 py-3 flex items-center justify-between z-10">
        <span className="text-sm text-muted-foreground">
          {t("print.previewHint")}
        </span>
        <button
          className="text-xs text-primary underline"
          onClick={() => window.print()}
        >
          {t("print.printAgain")}
        </button>
      </div>

      <div className="print:pt-0 pt-14 max-w-[720px] mx-auto px-10 py-12">
        <h1 className="text-3xl font-bold mb-2 text-foreground">
          {book?.title}
        </h1>
        <p className="text-sm text-muted-foreground mb-10">
          {book?.sourceLang} → {book?.targetLang} ·{" "}
          {t("print.pages", { count: pages.length })}
        </p>
        <hr className="mb-10 border-border" />

        {pages.map((page) => {
          const blocks = normalizeBlocks(page.targetText ?? "");
          return (
            <div key={page.id} className="mb-8">
              {blocks.map((block, i) =>
                block.type === "heading1" ? (
                  <h1
                    key={i}
                    className="text-2xl font-bold mt-10 mb-3 first:mt-0"
                  >
                    <InlineMarkdown text={block.text} />
                  </h1>
                ) : block.type === "heading2" ? (
                  <h2 key={i} className="text-lg font-semibold mt-6 mb-2">
                    <InlineMarkdown text={block.text} />
                  </h2>
                ) : block.type === "heading3" ? (
                  <h3 key={i} className="text-base font-semibold mt-4 mb-1">
                    <InlineMarkdown text={block.text} />
                  </h3>
                ) : block.type === "image" ? (
                  <img
                    key={i}
                    src={`${apiBase}/books/${bookId}/image-asset?path=${encodeURIComponent(block.src)}`}
                    alt={block.alt}
                    className="max-w-full h-auto my-4"
                  />
                ) : (
                  <p
                    key={i}
                    className="leading-relaxed mb-3 text-foreground/90"
                  >
                    <InlineMarkdown text={block.text} />
                  </p>
                ),
              )}
            </div>
          );
        })}
      </div>

      <style>{`
        @media print {
          @page { margin: 2cm; }
          body { font-family: serif; }
        }
      `}</style>
    </>
  );
}
