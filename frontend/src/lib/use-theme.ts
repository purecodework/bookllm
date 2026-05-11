"use client";

import { useEffect, useState } from "react";

const STORAGE_KEY = "bookllm:theme";

export type Theme = "dark" | "light";

export function useTheme() {
  const [theme, setThemeState] = useState<Theme>("dark");


  useEffect(() => {
    const saved = (localStorage.getItem(STORAGE_KEY) as Theme) ?? "dark";
    applyTheme(saved);
    setThemeState(saved);
  }, []);

  const setTheme = (t: Theme) => {
    localStorage.setItem(STORAGE_KEY, t);
    applyTheme(t);
    setThemeState(t);
  };

  return { theme, setTheme };
}

function applyTheme(t: Theme) {
  const html = document.documentElement;
  if (t === "dark") {
    html.classList.add("dark");
    html.classList.remove("light");
  } else {
    html.classList.add("light");
    html.classList.remove("dark");
  }
}
