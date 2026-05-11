import { normalizeBlocks } from "@/lib/text-normalize";
import { cn } from "@/lib/utils";
import { getApiBase } from "@/lib/api-base";

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

export function TextBlocks({
  text,
  fontSize,
  lineHeight,
  bookId,
}: {
  text: string;
  fontSize: string;
  lineHeight: string;
  bookId?: string;
}) {
  const blocks = normalizeBlocks(text);
  const apiBase = getApiBase();
  return (
    <div className={cn("space-y-3", fontSize, lineHeight)}>
      {blocks.map((block, i) =>
        block.type === "heading1" ? (
          <h1
            key={i}
            className="text-[1.4em] font-bold text-foreground mt-8 first:mt-0 tracking-tight"
          >
            <InlineMarkdown text={block.text} />
          </h1>
        ) : block.type === "heading2" ? (
          <h2
            key={i}
            className="text-[1.15em] font-semibold text-foreground mt-5 first:mt-0 tracking-tight"
          >
            <InlineMarkdown text={block.text} />
          </h2>
        ) : block.type === "heading3" ? (
          <h3
            key={i}
            className="text-[1.05em] font-semibold text-foreground mt-4 first:mt-0 tracking-tight"
          >
            <InlineMarkdown text={block.text} />
          </h3>
        ) : block.type === "image" ? (
          <figure key={i} className="my-5">
            {bookId ? (
              <img
                src={`${apiBase}/books/${bookId}/image-asset?path=${encodeURIComponent(block.src)}`}
                alt={block.alt}
                className="max-w-full h-auto rounded-md border border-border/60"
                loading="lazy"
              />
            ) : (
              <div className="text-xs text-muted-foreground border border-dashed rounded-md px-3 py-2">
                [Image unavailable]
              </div>
            )}
            {block.alt && block.alt !== "illustration" ? (
              <figcaption className="mt-1 text-xs text-muted-foreground">
                {block.alt}
              </figcaption>
            ) : null}
          </figure>
        ) : (
          <p key={i} className="text-foreground/90">
            <InlineMarkdown text={block.text} />
          </p>
        ),
      )}
    </div>
  );
}
