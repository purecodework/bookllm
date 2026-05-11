import { EpubParserService } from './epub-parser.service';

describe('EpubParserService', () => {
  let service: EpubParserService;

  beforeEach(() => {
    service = new EpubParserService();
  });


  describe('htmlToText', () => {
    const noImages = new Map<string, string>();

    it('converts inline HTML to text with markdown formatting', () => {
      const html = '<p>Hello <strong>world</strong></p>';
      expect(service.htmlToText(html, 'ch.html', noImages)).toBe('Hello **world**');
    });

    it('strips <style> blocks', () => {
      const html = '<style>body { color: red; }</style><p>visible</p>';
      expect(service.htmlToText(html, 'ch.html', noImages)).not.toContain('color');
      expect(service.htmlToText(html, 'ch.html', noImages)).toContain('visible');
    });

    it('strips <script> blocks', () => {
      const html = '<script>alert("xss")</script><p>safe</p>';
      const result = service.htmlToText(html, 'ch.html', noImages);
      expect(result).not.toContain('alert');
      expect(result).toContain('safe');
    });

    it('inserts double newlines around block elements (p, div, h1-h6, li)', () => {
      const html = '<p>Para one</p><p>Para two</p>';
      const result = service.htmlToText(html, 'ch.html', noImages);
      expect(result).toContain('Para one');
      expect(result).toContain('Para two');

      expect(result).toMatch(/Para one\n\nPara two/);
    });

    it('converts <br> and <hr> to single newlines', () => {
      const html = '<p>line one<br/>line two</p>';
      const result = service.htmlToText(html, 'ch.html', noImages);
      expect(result).toContain('line one');
      expect(result).toContain('line two');
    });

    it('decodes standard HTML entities', () => {
      const html = '<p>&amp; &lt; &gt; &quot; &#39;</p>';
      const result = service.htmlToText(html, 'ch.html', noImages);
      expect(result).toContain('& < > " \'');
    });

    it('replaces &nbsp; with a regular space', () => {
      const html = '<p>Hello&nbsp;world</p>';
      const result = service.htmlToText(html, 'ch.html', noImages);
      expect(result).toBe('Hello world');
    });

    it('normalises multiple consecutive spaces to a single space', () => {
      const html = '<p>too   many   spaces</p>';
      expect(service.htmlToText(html, 'ch.html', noImages)).toBe('too many spaces');
    });

    it('collapses 3+ consecutive newlines to exactly 2', () => {
      const html = '<p>A</p><div></div><div></div><p>B</p>';
      const result = service.htmlToText(html, 'ch.html', noImages);
      expect(result).not.toMatch(/\n{3,}/);
    });

    describe('image handling', () => {
      it('replaces <img> with an OB_IMAGE marker when the src is in imageFileMap', () => {
        const map = new Map([['OEBPS/images/fig1.png', 'images/fig1.png']]);
        const html = '<img src="images/fig1.png" alt="Figure 1"/>';
        const result = service.htmlToText(html, 'OEBPS/ch.html', map);
        expect(result).toContain('[[OB_IMAGE:images/fig1.png');
      });

      it('includes the alt attribute in the marker', () => {
        const map = new Map([['OEBPS/images/fig1.png', 'images/stored-fig1.png']]);
        const html = '<img src="images/fig1.png" alt="My caption"/>';
        const result = service.htmlToText(html, 'OEBPS/ch.html', map);
        expect(result).toContain('My caption');
      });

      it('replaces <img> with empty paragraph when src is NOT in imageFileMap', () => {
        const html = '<img src="unknown.png" alt="missing"/>';
        const result = service.htmlToText(html, 'ch.html', noImages);
        expect(result).not.toContain('[[OB_IMAGE:');
        expect(result).not.toContain('missing');
      });

      it('resolves relative src paths relative to the chapter directory', () => {
        const map = new Map([['OEBPS/images/cover.jpg', 'images/cover.jpg']]);
        const html = '<img src="../images/cover.jpg"/>';

        const result = service.htmlToText(html, 'OEBPS/content/ch.html', map);
        expect(result).toContain('[[OB_IMAGE:images/cover.jpg');
      });

      it('ignores external http:// image URLs', () => {
        const html = '<img src="https://example.com/img.png" alt="external"/>';
        const result = service.htmlToText(html, 'ch.html', noImages);
        expect(result).not.toContain('[[OB_IMAGE:');
      });

      it('ignores data: URI images', () => {
        const html = '<img src="data:image/png;base64,abc123" alt="inline"/>';
        const result = service.htmlToText(html, 'ch.html', noImages);
        expect(result).not.toContain('[[OB_IMAGE:');
      });
    });
  });


  describe('parseOpfManifestItems', () => {
    it('extracts id, href, and media-type from manifest items', () => {
      const opf = `
        <manifest>
          <item id="ch1" href="OEBPS/ch1.html" media-type="application/xhtml+xml"/>
          <item id="img1" href="OEBPS/images/fig.png" media-type="image/png"/>
        </manifest>`;
      const items = service.parseOpfManifestItems(opf, '');
      expect(items).toHaveLength(2);
      expect(items[0]).toMatchObject({ id: 'ch1', href: 'OEBPS/ch1.html', mediaType: 'application/xhtml+xml' });
      expect(items[1]).toMatchObject({ id: 'img1', href: 'OEBPS/images/fig.png', mediaType: 'image/png' });
    });

    it('prepends opfDir to relative hrefs', () => {
      const opf = `<manifest>
        <item id="c1" href="Text/ch1.html" media-type="application/xhtml+xml"/>
      </manifest>`;
      const items = service.parseOpfManifestItems(opf, 'OEBPS/');
      expect(items[0].href).toBe('OEBPS/Text/ch1.html');
    });

    it('extracts the cover-image property when present', () => {
      const opf = `<manifest>
        <item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
      </manifest>`;
      const items = service.parseOpfManifestItems(opf, '');
      expect(items[0].properties).toBe('cover-image');
    });

    it('returns an empty array for an empty manifest', () => {
      expect(service.parseOpfManifestItems('<manifest></manifest>', '')).toHaveLength(0);
    });
  });


  describe('parseOpfSpine', () => {
    it('returns idref values in spine order', () => {
      const opf = `
        <spine>
          <itemref idref="ch1"/>
          <itemref idref="ch2"/>
          <itemref idref="ch3"/>
        </spine>`;
      expect(service.parseOpfSpine(opf)).toEqual(['ch1', 'ch2', 'ch3']);
    });

    it('returns empty array when there is no spine element', () => {
      expect(service.parseOpfSpine('<package/>')).toEqual([]);
    });
  });


  describe('epubHasImages', () => {
    it('returns true when manifest contains image media types', () => {
      const opf = `<item id="img" href="cover.jpg" media-type="image/jpeg"/>`;
      expect(service.epubHasImages(opf)).toBe(true);
    });

    it('returns false when manifest has no image media types', () => {
      const opf = `<item id="ch1" href="ch1.html" media-type="application/xhtml+xml"/>`;
      expect(service.epubHasImages(opf)).toBe(false);
    });
  });


  describe('pickEpubCoverHref', () => {
    it('prefers item with properties="cover-image"', () => {
      const opf = `
        <manifest>
          <item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
          <item id="img1" href="other.jpg" media-type="image/jpeg"/>
        </manifest>`;
      const items = service.parseOpfManifestItems(opf, '');
      expect(service.pickEpubCoverHref(opf, items)).toBe('cover.jpg');
    });

    it('falls back to <meta name="cover"> reference', () => {
      const opf = `
        <metadata>
          <meta name="cover" content="my-cover"/>
        </metadata>
        <manifest>
          <item id="my-cover" href="images/cover.png" media-type="image/png"/>
        </manifest>`;
      const items = service.parseOpfManifestItems(opf, '');
      expect(service.pickEpubCoverHref(opf, items)).toBe('images/cover.png');
    });

    it('returns null when no cover is found', () => {
      const opf = `<manifest><item id="ch" href="ch.html" media-type="application/xhtml+xml"/></manifest>`;
      const items = service.parseOpfManifestItems(opf, '');
      expect(service.pickEpubCoverHref(opf, items)).toBeNull();
    });
  });


  describe('normalizePath', () => {
    it('resolves .. segments', () => {
      expect(service.normalizePath('OEBPS/content/../images/fig.png')).toBe('OEBPS/images/fig.png');
    });

    it('resolves . segments', () => {
      expect(service.normalizePath('OEBPS/./ch1.html')).toBe('OEBPS/ch1.html');
    });

    it('handles multiple consecutive .. segments', () => {
      expect(service.normalizePath('a/b/c/../../d.html')).toBe('a/d.html');
    });

    it('returns simple path unchanged', () => {
      expect(service.normalizePath('OEBPS/ch1.html')).toBe('OEBPS/ch1.html');
    });
  });
});
