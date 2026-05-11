"use client";

export function FieldLabel({ label, hint }: { label: string; hint?: string }) {
  return (
    <div className="flex items-center gap-1.5">
      <label className="text-xs font-medium text-muted-foreground">{label}</label>
      {hint && (
        <span className="rounded-full bg-secondary px-1.5 py-0.5 text-[10px] text-muted-foreground">
          {hint}
        </span>
      )}
    </div>
  );
}

