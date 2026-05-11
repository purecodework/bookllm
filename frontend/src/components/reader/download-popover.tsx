"use client";

import { useState } from "react";
import { Download, FileText, BookOpen, Printer } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Separator } from "@/components/ui/separator";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import { getApiBase } from "@/lib/api-base";

interface DownloadPopoverProps {
  bookId: string;
  status: string;
  hasTranslated: boolean;
  size?: "sm" | "default";
}

type Format = "pdf" | "epub" | "txt";

export function DownloadPopover({
  bookId,
  status,
  hasTranslated,
  size = "default",
}: DownloadPopoverProps) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [pendingFormat, setPendingFormat] = useState<Format | null>(null);
  const formats: {
    format: Format;
    label: string;
    ext: string;
    icon: typeof FileText;
  }[] = [
    {
      format: "pdf",
      label: "PDF",
      ext: t("download.printExport"),
      icon: Printer,
    },
    { format: "epub", label: "EPUB", ext: ".epub", icon: BookOpen },
    { format: "txt", label: "TXT", ext: ".txt", icon: FileText },
  ];

  const apiBase = getApiBase();

  const executeDownload = (format: Format) => {
    const a = document.createElement("a");
    a.href = `${apiBase}/books/${bookId}/download/${format}`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  };

  const handleFormatClick = (format: Format) => {
    setOpen(false);
    if (status !== "completed") {
      setPendingFormat(format);
    } else {
      executeDownload(format);
    }
  };

  return (
    <>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button
            variant="ghost"
            size="icon"
            className={cn(
              "shrink-0",
              size === "sm"
                ? "h-7 w-7 text-muted-foreground hover:text-foreground"
                : "h-8 w-8",
            )}
            disabled={!hasTranslated}
            title={t("common.download")}
            onClick={(e: React.MouseEvent) => e.stopPropagation()}
          >
            <Download className={size === "sm" ? "h-3.5 w-3.5" : "h-4 w-4"} />
          </Button>
        </PopoverTrigger>

        <PopoverContent
          className="w-44 p-1"
          align="end"
          onClick={(e: React.MouseEvent) => e.stopPropagation()}
        >
          <p className="px-2 py-1.5 text-xs font-medium text-muted-foreground">
            {t("common.download")}
          </p>
          <Separator className="mb-1" />
          {formats.map(({ format, label, ext, icon: Icon }) => (
            <button
              key={format}
              className="w-full flex items-center justify-between px-2 py-1.5 rounded-sm text-sm hover:bg-secondary transition-colors"
              onClick={() => handleFormatClick(format)}
            >
              <div className="flex items-center gap-2">
                <Icon className="h-3.5 w-3.5 text-muted-foreground" />
                <span>{label}</span>
              </div>
              <span className="text-xs text-muted-foreground">{ext}</span>
            </button>
          ))}
        </PopoverContent>
      </Popover>

      <AlertDialog
        open={pendingFormat !== null}
        onOpenChange={(o: boolean) => !o && setPendingFormat(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("download.incompleteTitle")}</AlertDialogTitle>
            <AlertDialogDescription>
              {t("download.incompleteDesc")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => setPendingFormat(null)}>
              {t("common.cancel")}
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (pendingFormat) executeDownload(pendingFormat);
                setPendingFormat(null);
              }}
            >
              {t("download.continue")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
