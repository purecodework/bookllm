import * as path from 'path';


export function resolveStorageRoot(): string {
  const configured = process.env.ORIGINAL_ASSET_DIR;
  if (configured && configured.trim()) return configured.trim();
  return path.resolve(process.cwd(), 'data', 'original-assets');
}
