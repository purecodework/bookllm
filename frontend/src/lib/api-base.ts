const DEFAULT_API_URL = "http://localhost:3001";


export function getApiBase(): string {
  if (typeof window !== "undefined") {
    return (
      (window as Window & { __OB_API_URL__?: string }).__OB_API_URL__ ??
      DEFAULT_API_URL
    );
  }

  return process.env.API_URL ?? DEFAULT_API_URL;
}
