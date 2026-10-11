#!/usr/bin/env python3
"""Rebuild the portable UI reference. Uses only Python's standard library."""
from pathlib import Path
import base64
import re
import mimetypes
ROOT=Path(__file__).resolve().parents[1]
html=(ROOT/'prototype/index.html').read_text(encoding='utf-8')
css=(ROOT/'prototype/styles.css').read_text(encoding='utf-8')
js=(ROOT/'prototype/app.js').read_text(encoding='utf-8')
html=re.sub(r'<link[^>]*href="styles.css"[^>]*>',lambda _: '<style>'+css+'</style>',html)
html=re.sub(r'<script[^>]*src="app.js"[^>]*></script>',lambda _: '<script>'+js+'</script>',html)
for rel in set(re.findall(r'\.\./assets/[A-Za-z0-9_@/.-]+',html)):
 path=(ROOT/'prototype'/rel).resolve()
 if not path.is_relative_to(ROOT/'assets') or not path.is_file():raise RuntimeError(f'Invalid asset: {rel}')
 mime=mimetypes.guess_type(str(path))[0] or 'application/octet-stream'
 if mime.startswith('font/') or path.suffix.lower() in {'.ttf','.otf','.woff','.woff2'}:raise RuntimeError('Font files are not distributed.')
 html=html.replace(rel,'data:'+mime+';base64,'+base64.b64encode(path.read_bytes()).decode())
(ROOT/'preview.html').write_text(html,encoding='utf-8')
print(f'Wrote preview.html ({len(html.encode()):,} bytes)')
