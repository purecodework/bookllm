import { Injectable } from '@nestjs/common';
import { renderImageMarker } from '../common/image-markers';

export interface EpubManifestItem {
  id: string;
  href: string;
  mediaType: string;
  properties?: string;
}

@Injectable()
export class EpubParserService {
  parseOpfManifestItems(opfXml: string, opfDir: string): EpubManifestItem[] {
    const manifest: EpubManifestItem[] = [];
    const itemRegex = /<item\b([^>]*)\/?\s*>/gi;
    let match: RegExpExecArray | null;
    while ((match = itemRegex.exec(opfXml)) !== null) {
      const attrs = match[1];
      const idMatch = attrs.match(/\bid=["']([^"']+)["']/i);
      const hrefMatch = attrs.match(/\bhref=["']([^"']+)["']/i);
      const mediaTypeMatch = attrs.match(/\bmedia-type=["']([^"']+)["']/i);
      if (idMatch && hrefMatch && mediaTypeMatch) {
        const href = hrefMatch[1];
        const fullHref = href.startsWith('/')
          ? href.slice(1)
          : this.normalizePath(`${opfDir}${href}`);
        const propertiesMatch = attrs.match(/\bproperties=["']([^"']+)["']/i);
        manifest.push({
          id: idMatch[1],
          href: fullHref,
          mediaType: mediaTypeMatch[1],
          properties: propertiesMatch?.[1] ?? '',
        });
      }
    }
    return manifest;
  }

  parseOpfSpine(opfXml: string): string[] {
    const spineMatch = opfXml.match(/<spine[^>]*>([\s\S]*?)<\/spine>/i);
    if (!spineMatch) return [];
    const ids: string[] = [];
    const itemrefRegex = /<itemref\b[^>]*\bidref=["']([^"']+)["']/gi;
    let match: RegExpExecArray | null;
    while ((match = itemrefRegex.exec(spineMatch[1])) !== null) {
      ids.push(match[1]);
    }
    return ids;
  }

  htmlToText(
    html: string,
    chapterPath: string,
    imageFileMap: Map<string, string>,
  ): string {
    const chapterDir = chapterPath.includes('/')
      ? chapterPath.slice(0, chapterPath.lastIndexOf('/') + 1)
      : '';
    return html
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '')
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
      .replace(/<img\b([^>]*)\/?>/gi, (_full: string, attrs: string) => {
        const srcMatch = attrs.match(/\bsrc=["']([^"']+)["']/i);
        if (!srcMatch) return '\n\n';
        const altMatch = attrs.match(/\balt=["']([^"']+)["']/i);
        const resolved = this.resolveRelativePath(chapterDir, srcMatch[1]);
        const storedPath = imageFileMap.get(resolved);
        if (!storedPath) return '\n\n';
        return `\n\n${renderImageMarker(storedPath, this.decodeHtmlEntities(altMatch?.[1] ?? ''))}\n\n`;
      })

      .replace(/<h1\b[^>]*>([\s\S]*?)<\/h1>/gi, '\n\n# $1\n\n')
      .replace(/<h2\b[^>]*>([\s\S]*?)<\/h2>/gi, '\n\n## $1\n\n')
      .replace(/<h3\b[^>]*>([\s\S]*?)<\/h3>/gi, '\n\n### $1\n\n')
      .replace(/<h4\b[^>]*>([\s\S]*?)<\/h4>/gi, '\n\n#### $1\n\n')
      .replace(/<h5\b[^>]*>([\s\S]*?)<\/h5>/gi, '\n\n##### $1\n\n')
      .replace(/<h6\b[^>]*>([\s\S]*?)<\/h6>/gi, '\n\n###### $1\n\n')

      .replace(/<(?:strong|b)\b[^>]*>([\s\S]*?)<\/(?:strong|b)>/gi, '**$1**')
      .replace(/<(?:em|i)\b[^>]*>([\s\S]*?)<\/(?:em|i)>/gi, '*$1*')
      .replace(/<(br|hr)\s*\/?>/gi, '\n')
      .replace(/<\/?(p|div|li|tr|blockquote)[^>]*>/gi, '\n\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/[ \t]+/g, ' ')
      .replace(/\n[ \t]+/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim()
      .replace(/[^\S\n]+/g, ' ')
      .split('\n')
      .map((line) => this.decodeHtmlEntities(line))
      .join('\n')
      .trim();
  }

  pickEpubCoverHref(opfXml: string, manifestItems: EpubManifestItem[]): string | null {
    const coverByProperties = manifestItems.find((item) =>
      (item.properties ?? '')
        .split(/\s+/)
        .map((value) => value.trim().toLowerCase())
        .includes('cover-image'),
    );
    if (coverByProperties?.href) return coverByProperties.href;

    const coverMeta = opfXml.match(/<meta\b[^>]*\bname=["']cover["'][^>]*\bcontent=["']([^"']+)["']/i);
    if (coverMeta?.[1]) {
      const byId = manifestItems.find((item) => item.id === coverMeta[1]);
      if (byId?.href) return byId.href;
    }
    return null;
  }

  epubHasImages(opfXml: string): boolean {
    return /media-type=["']image\//i.test(opfXml);
  }

  normalizePath(value: string): string {
    const parts = value.split('/');
    const out: string[] = [];
    for (const segment of parts) {
      if (segment === '..') out.pop();
      else if (segment !== '.') out.push(segment);
    }
    return out.join('/');
  }

  private resolveRelativePath(baseDir: string, maybeRelative: string): string {
    if (/^https?:\/\//i.test(maybeRelative) || maybeRelative.startsWith('data:')) return '';
    if (maybeRelative.startsWith('/')) return maybeRelative.slice(1);
    return this.normalizePath(`${baseDir}${maybeRelative}`);
  }

  private decodeHtmlEntities(text: string): string {
    return text
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&apos;/g, "'");
  }
}
