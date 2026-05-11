export const IMAGE_MARKER_PREFIX = '[[OB_IMAGE:';

export function imageMarkerRegex(): RegExp {
  return /\[\[OB_IMAGE:([^\]|]+)(?:\|([^\]]*))?\]\]/g;
}

function sanitize(text: string): string {
  return text.replace(/[|\]]/g, ' ').trim();
}

export function renderImageMarker(relativePath: string, alt = ''): string {
  const safePath = sanitize(relativePath);
  const safeAlt = sanitize(alt);
  return safeAlt ? `${IMAGE_MARKER_PREFIX}${safePath}|${safeAlt}]]` : `${IMAGE_MARKER_PREFIX}${safePath}]]`;
}

export function parseImageMarkers(text: string): Array<{ path: string; alt: string }> {
  const out: Array<{ path: string; alt: string }> = [];
  for (const match of text.matchAll(imageMarkerRegex())) {
    const markerPath = (match[1] ?? '').trim();
    if (!markerPath) continue;
    out.push({ path: markerPath, alt: (match[2] ?? '').trim() });
  }
  return out;
}

export function ensureImageMarkersInTarget(sourceText: string, targetText: string): string {
  const sourceMarkers = parseImageMarkers(sourceText);
  if (sourceMarkers.length === 0) return targetText;

  const seen = new Set(parseImageMarkers(targetText).map((m) => m.path));
  const missing = sourceMarkers.filter((m) => !seen.has(m.path)).map((m) => renderImageMarker(m.path, m.alt));

  if (missing.length === 0) return targetText;
  return `${targetText.trim()}\n\n${missing.join('\n\n')}`.trim();
}
