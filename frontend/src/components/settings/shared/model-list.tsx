"use client";

import { cn } from "@/lib/utils";

export function ModelList({
  models,
  selectedModel,
  onSelect,
  maxHeightClass = "max-h-[160px]",
}: {
  models: string[];
  selectedModel: string;
  onSelect: (model: string) => void;
  maxHeightClass?: string;
}) {
  return (
    <div className={cn(maxHeightClass, "space-y-1 overflow-y-auto rounded-xl")}>
      {models.map((model) => (
        <button
          key={model}
          type="button"
          onClick={() => onSelect(model)}
          className={cn(
            "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm transition-colors",
            selectedModel === model ? "bg-primary/10 text-primary" : "text-foreground hover:bg-secondary",
          )}
        >
          <span
            className={cn(
              "h-1.5 w-1.5 shrink-0 rounded-full",
              selectedModel === model ? "bg-primary" : "bg-muted-foreground/40",
            )}
          />
          <span className="truncate font-mono text-xs">{model}</span>
        </button>
      ))}
    </div>
  );
}

export function SelectedModelPill({ model }: { model: string }) {
  return (
    <div className="flex items-center gap-2 rounded-lg border border-border/50 bg-secondary/30 px-3 py-2">
      <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-primary" />
      <span className="truncate font-mono text-xs text-foreground">{model}</span>
    </div>
  );
}

