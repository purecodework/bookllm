"use client";

import Link from "next/link";
import {
  ArrowUpRight,
  BookOpen,
  LayoutGrid,
  List,
  Loader2,
  Trash2,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { DownloadPopover } from "@/components/reader/download-popover";
import { useI18n } from "@/lib/i18n";
import { deleteBook, type Book } from "@/lib/api";
import { getApiBase } from "@/lib/api-base";
import { cleanTitle, cn, formatRelativeTime } from "@/lib/utils";
import { useState } from "react";

const COVER_COLORS = [
  "#2f6fed",
  "#4b7a8d",
  "#786f61",
  "#66746a",
  "#6f6a86",
  "#5f756f",
  "#7a6a5d",
  "#5f6f91",
];

type BookLibraryProps = {
  books: Book[];
  normalizedSearch: string;
  onDelete: (id: string) => void;
};

function coverColor(id: string) {
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) & 0xffffffff;
  return COVER_COLORS[Math.abs(h) % COVER_COLORS.length];
}

export function BookCardSkeleton() {
  return (
    <Card className="overflow-hidden">
      <CardContent className="p-4">
        <div className="flex items-start gap-3 mb-3">
          <Skeleton className="h-28 w-20 rounded-md shrink-0" />
          <div className="flex-1 pt-1 space-y-2">
            <Skeleton className="h-4 w-14" />
            <Skeleton className="h-4 w-full" />
            <Skeleton className="h-4 w-3/4" />
          </div>
        </div>
        <Skeleton className="h-1.5 w-full mb-2" />
        <Skeleton className="h-3 w-20" />
      </CardContent>
    </Card>
  );
}

function BookCover({
  id,
  title,
  coverUrl,
  size = "md",
}: {
  id: string;
  title: string;
  coverUrl?: string | null;
  size?: "sm" | "md";
}) {
  const cls = size === "sm" ? "h-14 w-10" : "h-28 w-20";
  if (coverUrl) {
    return (
      <div
        className={cn(
          "rounded-md overflow-hidden shrink-0 bg-secondary shadow-sm ring-1 ring-border",
          cls,
        )}
      >
        <img
          src={getApiBase() + coverUrl}
          alt={cleanTitle(title)}
          className="h-full w-full object-cover"
          loading="lazy"
        />
      </div>
    );
  }
  return (
    <div
      className={cn(
        "rounded-md flex items-center justify-center shrink-0 bg-muted shadow-sm ring-1 ring-border",
        cls,
      )}
      style={{ backgroundColor: coverColor(id) }}
    >
      <BookOpen className="h-5 w-5 text-white/75" />
    </div>
  );
}

function statusMeta(t: ReturnType<typeof useI18n>["t"], status: string) {
  const labels: Record<string, string> = {
    pending: t("home.status.pending"),
    processing: t("home.status.processing"),
    completed: t("home.status.completed"),
    failed: t("home.status.failed"),
  };
  const variants: Record<
    string,
    "success" | "processing" | "pending" | "destructive" | "secondary"
  > = {
    pending: "pending",
    processing: "processing",
    completed: "success",
    failed: "destructive",
  };
  return {
    label: labels[status] ?? labels.pending,
    variant: variants[status] ?? "pending",
  };
}

function DeleteButton({
  book,
  onDelete,
}: {
  book: Book;
  onDelete: (id: string) => void;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleDelete = async () => {
    setLoading(true);
    try {
      await deleteBook(book.id);
      onDelete(book.id);
      setOpen(false);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          data-testid="delete-book-btn"
          className="h-7 w-7 text-muted-foreground hover:text-destructive hover:bg-destructive/10"
          onClick={(e) => e.stopPropagation()}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("home.deleteConfirmTitle")}</DialogTitle>
          <DialogDescription>
            {t("home.deleteConfirmDescription", {
              title: cleanTitle(book.title),
            })}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)}>
            {t("common.cancel")}
          </Button>
          <Button
            variant="destructive"
            onClick={handleDelete}
            disabled={loading}
          >
            {loading && <Loader2 className="h-4 w-4 animate-spin mr-1" />}
            {t("common.delete")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function BookCard({
  book,
  onDelete,
}: {
  book: Book;
  onDelete: (id: string) => void;
}) {
  const { t, languageName, locale } = useI18n();
  const status = statusMeta(t, book.status);
  return (
    <Card className="group relative overflow-hidden bg-background/95 transition-all duration-200 hover:border-primary/25 hover:shadow-md hover:-translate-y-px cursor-pointer">
      <Link href={`/book/${book.id}`} className="block">
        <CardContent className="p-4">
          <div className="flex items-start gap-3 mb-3">
            <BookCover id={book.id} title={book.title} coverUrl={book.coverUrl} />
            <div className="flex-1 min-w-0 pt-1">
              <Badge variant={status.variant} className="mb-1.5 text-[11px]">
                {status.label}
              </Badge>
              <h3 className="font-semibold text-sm text-foreground line-clamp-2 leading-snug">
                {cleanTitle(book.title)}
              </h3>
            </div>
          </div>
          <div className="flex items-center gap-1.5 mb-2.5">
            <span className="text-xs text-muted-foreground">
              {languageName(book.sourceLang)}
            </span>
            <ArrowUpRight className="h-3 w-3 text-muted-foreground" />
            <span className="text-xs text-muted-foreground">
              {languageName(book.targetLang)}
            </span>
            {book.status === "processing" && (
              <span className="text-xs text-primary ml-auto font-mono">
                {book.translationProgress ?? 0}%
              </span>
            )}
          </div>
          <Progress value={book.translationProgress ?? 0} className="h-[3px] mb-2" />
          <span className="text-[11px] text-muted-foreground font-mono">
            {formatRelativeTime(book.updatedAt, locale)}
          </span>
        </CardContent>
      </Link>
      <div className="absolute top-2 right-2 flex items-center gap-0.5 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
        <DownloadPopover
          bookId={book.id}
          status={book.status}
          hasTranslated={(book.translationProgress ?? 0) > 0}
          size="sm"
        />
        <DeleteButton book={book} onDelete={onDelete} />
      </div>
    </Card>
  );
}

function EmptyBooks({ normalizedSearch }: { normalizedSearch: string }) {
  const { t } = useI18n();
  return (
    <div className="flex flex-col items-center justify-center py-24 text-center">
      <BookOpen className="h-12 w-12 text-muted-foreground mb-4 opacity-40" />
      <h3 className="text-base font-semibold text-foreground mb-2">
        {normalizedSearch ? t("home.noMatch") : t("home.noDocs")}
      </h3>
      <p className="text-sm text-muted-foreground mb-4">
        {normalizedSearch
          ? t("home.noResultFor", { query: normalizedSearch })
          : t("home.uploadPrompt")}
      </p>
      {!normalizedSearch && (
        <Button asChild>
          <Link href="/upload">{t("home.uploadFirst")}</Link>
        </Button>
      )}
    </div>
  );
}

function BookGrid(props: BookLibraryProps) {
  if (props.books.length === 0) {
    return <EmptyBooks normalizedSearch={props.normalizedSearch} />;
  }
  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
      {props.books.map((book) => (
        <BookCard key={book.id} book={book} onDelete={props.onDelete} />
      ))}
    </div>
  );
}

function BookTable({ books, onDelete }: BookLibraryProps) {
  const { t, languageName, locale } = useI18n();
  return (
    <div className="glass-card overflow-x-auto rounded-xl">
      <Table>
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            <TableHead className="w-[280px]">{t("home.tableTitle")}</TableHead>
            <TableHead>{t("home.tableLanguages")}</TableHead>
            <TableHead>{t("home.tableStatus")}</TableHead>
            <TableHead>{t("home.tableUpdated")}</TableHead>
            <TableHead className="w-[60px]" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {books.map((book) => {
            const status = statusMeta(t, book.status);
            return (
              <TableRow key={book.id}>
                <TableCell>
                  <Link href={`/book/${book.id}`} className="flex items-center gap-3 group">
                    <BookCover id={book.id} title={book.title} coverUrl={book.coverUrl} size="sm" />
                    <p className="font-medium text-sm group-hover:text-primary transition-colors truncate">
                      {cleanTitle(book.title)}
                    </p>
                  </Link>
                </TableCell>
                <TableCell className="text-sm text-muted-foreground">
                  {languageName(book.sourceLang)} → {languageName(book.targetLang)}
                </TableCell>
                <TableCell>
                  <Badge variant={status.variant}>{status.label}</Badge>
                </TableCell>
                <TableCell className="text-sm text-muted-foreground">
                  <div className="flex items-center justify-between gap-2">
                    <span>{formatRelativeTime(book.updatedAt, locale)}</span>
                    {book.status === "processing" && (
                      <span className="text-xs text-primary font-mono">
                        {book.translationProgress ?? 0}%
                      </span>
                    )}
                  </div>
                </TableCell>
                <TableCell>
                  <DeleteButton book={book} onDelete={onDelete} />
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}

export function BookLibrary(props: BookLibraryProps) {
  const { t } = useI18n();
  return (
    <Tabs defaultValue="cards">
      <div className="mb-4 hidden items-center justify-between sm:flex">
        <TabsList className="glass-panel h-9 p-1 rounded-xl gap-0.5 shadow-[var(--glass-shadow-1)]">
          <TabsTrigger
            value="cards"
            className="h-7 px-3 rounded-lg text-xs font-medium data-[state=active]:bg-primary data-[state=active]:text-primary-foreground data-[state=active]:shadow-none gap-1.5"
          >
            <LayoutGrid className="h-3.5 w-3.5" />
            {t("home.cards")}
          </TabsTrigger>
          <TabsTrigger
            value="table"
            className="h-7 px-3 rounded-lg text-xs font-medium data-[state=active]:bg-primary data-[state=active]:text-primary-foreground data-[state=active]:shadow-none gap-1.5"
          >
            <List className="h-3.5 w-3.5" />
            {t("home.list")}
          </TabsTrigger>
        </TabsList>
      </div>

      <div className="sm:hidden">
        <BookGrid {...props} />
      </div>

      <TabsContent value="cards" className="mt-4 hidden sm:block">
        <BookGrid {...props} />
      </TabsContent>

      <TabsContent value="table" className="mt-4 hidden sm:block">
        {props.books.length === 0 ? (
          <EmptyBooks normalizedSearch={props.normalizedSearch} />
        ) : (
          <BookTable {...props} />
        )}
      </TabsContent>
    </Tabs>
  );
}
