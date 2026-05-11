export type Block =
  | { type: "heading1" | "heading2" | "heading3"; text: string }
  | { type: "paragraph"; text: string }
  | { type: "image"; src: string; alt: string };


function headingLevel(line: string): 1 | 2 | null {
  if (line.length > 120) return null;

  if (
    /^(chapter|part|第.章|prologue|epilogue|preface|introduction|appendix)\b/i.test(
      line,
    )
  )
    return 1;
  if (
    /^(I{1,3}|IV|VI{0,3}|IX|X{1,3}|XI{1,2}|XIV|XV|XVI{0,3}|XIX|XX)\.?\s*$/i.test(
      line,
    )
  )
    return 1;

  return null;
}


function parseChunk(text: string): Block {
  const imageMatch = text.match(/^\[\[OB_IMAGE:([^\]|]+)(?:\|([^\]]*))?\]\]$/);
  if (imageMatch) {
    return {
      type: "image",
      src: imageMatch[1].trim(),
      alt: (imageMatch[2] ?? "illustration").trim() || "illustration",
    };
  }


  if (/^#{1,6}\s/.test(text)) {
    const content = text.replace(/^#+\s*/, "").trim();

    if (/^["'“”‘’「『《（(]/.test(content)) {
      return { type: "paragraph", text: content };
    }
    if (/^#{3,}\s/.test(text)) return { type: "heading2", text: content };
    if (/^##\s/.test(text)) return { type: "heading2", text: content };
    return { type: "heading1", text: content };
  }

  const level = headingLevel(text);
  return {
    type: level === 1 ? "heading1" : level === 2 ? "heading2" : "paragraph",
    text,
  };
}

export function normalizeBlocks(raw: string): Block[] {
  const hasDoubleNewlines = /\n\n/.test(raw);

  const chunks = hasDoubleNewlines ? raw.split(/\n{2,}/) : raw.split(/\n/);

  const blocks: Block[] = [];

  for (const chunk of chunks) {
    const text = hasDoubleNewlines
      ? chunk
          .split("\n")
          .map((l) => l.trim())
          .filter(Boolean)
          .join(" ")
          .trim()
      : chunk.trim();

    if (!text) continue;
    blocks.push(parseChunk(text));
  }

  return blocks;
}
