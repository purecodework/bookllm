export function parseSseJson<T>(data: string): T | null {
  try {
    const parsed = JSON.parse(data) as unknown;
    if (typeof parsed === "string") {
      return JSON.parse(parsed) as T;
    }
    return parsed as T;
  } catch {
    return null;
  }
}
