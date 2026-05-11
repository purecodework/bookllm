"use client";

import { cn } from "@/lib/utils";

interface GlassToggleProps {
  checked: boolean;
  onChange: (checked: boolean) => void;
  label?: string;
  hint?: string;
  disabled?: boolean;
}

export function GlassToggle({
  checked,
  onChange,
  label,
  hint,
  disabled = false,
}: GlassToggleProps) {
  const handleToggle = () => {
    if (!disabled) onChange(!checked);
  };

  return (
    <div
      className={cn(
        "flex cursor-pointer items-start gap-3",
        disabled && "cursor-not-allowed opacity-50",
      )}
      onClick={handleToggle}
    >
      {}
      <div
        role="switch"
        aria-checked={checked}
        tabIndex={0}
        onKeyDown={(e) => (e.key === " " || e.key === "Enter") && handleToggle()}
        className={cn(
          "relative mt-0.5 h-6 w-11 shrink-0 overflow-hidden rounded-full transition-all duration-200",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
          checked
            ? "bg-primary shadow-[0_0_0_1px_rgba(47,111,237,0.4),0_2px_8px_rgba(47,111,237,0.28)]"
            : "glass-toggle-track",
        )}
      >
        {}
        <span
          className={cn(
            "absolute top-[2px] h-5 w-5 rounded-full bg-white transition-all duration-200 ease-[cubic-bezier(.34,1.5,.64,1)]",
            "shadow-[inset_0_-1px_2px_rgba(0,0,0,0.08),inset_0_1px_0_rgba(255,255,255,0.95),0_1px_3px_rgba(0,0,0,0.18)]",
            checked ? "left-[22px]" : "left-[2px]",
          )}
        />
      </div>

      {(label || hint) && (
        <div className="min-w-0 flex-1 space-y-0.5">
          {label && (
            <p className="text-sm font-medium leading-snug">{label}</p>
          )}
          {hint && (
            <p className="text-[11px] leading-relaxed text-muted-foreground/65">
              {hint}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
