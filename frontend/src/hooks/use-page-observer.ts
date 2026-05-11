"use client";

import { useState, useEffect, type RefObject } from "react";
import type { Page } from "@/lib/api";

export function usePageObserver(
  visiblePages: Page[],
  pageRefs: RefObject<Map<string, HTMLDivElement>>,
) {
  const [activePageId, setActivePageId] = useState<string | null>(null);

  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => {
        let best: { id: string; ratio: number } | null = null;
        for (const entry of entries) {
          if (entry.isIntersecting) {
            const id = entry.target.getAttribute("data-page-id") ?? "";
            if (!best || entry.intersectionRatio > best.ratio) {
              best = { id, ratio: entry.intersectionRatio };
            }
          }
        }
        if (best) setActivePageId(best.id);
      },
      { threshold: [0.1, 0.5], rootMargin: "-10% 0px -30% 0px" },
    );
    pageRefs.current?.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, [visiblePages, pageRefs]);

  return { activePageId };
}
