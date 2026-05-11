"use client";

import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

type PipelineStep = {
  id: string;
  active: boolean;
  content: ReactNode;
};

export function TranslationPipeline({
  title,
  steps,
}: {
  title: string;
  steps: PipelineStep[];
}) {
  return (
    <section className="space-y-4">
      <h2 className="text-[18px] font-semibold tracking-tight">{title}</h2>

      <div className="relative space-y-5">
        {steps.map((step, index) => (
          <div key={step.id} className="relative">
            <span
              aria-hidden="true"
              data-pipeline-rail="dot"
              className={cn(
                "absolute -left-[31px] top-8 z-10 hidden h-3 w-3 rounded-full ring-4 ring-background md:block",
                step.active
                  ? "bg-primary"
                  : "border-2 border-primary bg-background",
              )}
            />
            {index < steps.length - 1 && (
              <span
                aria-hidden="true"
                data-pipeline-rail="line"
                className="absolute -left-[25.5px] top-[48px] bottom-[-16px] hidden border-l border-dashed border-muted-foreground/35 md:block"
              />
            )}
            {index === steps.length - 1 && (
              <span
                aria-hidden="true"
                data-pipeline-arrow="true"
                data-pipeline-rail="line"
                className={cn(
                  "absolute -left-[25.5px] top-[48px] hidden border-l border-dashed border-muted-foreground/35 after:absolute after:-left-[4px] after:bottom-0 after:h-2 after:w-2 after:rotate-45 after:border-b after:border-r after:border-muted-foreground/55 md:block",
                  step.active ? "h-24" : "h-14",
                )}
              />
            )}
            {step.content}
          </div>
        ))}
      </div>
    </section>
  );
}
