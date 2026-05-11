"use client";

import { useState, useCallback, useRef } from "react";

const SIDEBAR_WIDTH = 220;

export function useSplitPane() {
  const containerRef = useRef<HTMLDivElement>(null);
  const [splitRatio, setSplitRatio] = useState(0.5);
  const [isCollapsed, setIsCollapsed] = useState(false);
  const [isDividerHovered, setIsDividerHovered] = useState(false);
  const lastRatioRef = useRef(0.5);

  const handleDividerMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    const onMouseMove = (ev: MouseEvent) => {
      if (!containerRef.current) return;
      const rect = containerRef.current.getBoundingClientRect();
      const ratio = (ev.clientX - rect.left) / rect.width;
      const clamped = Math.min(0.8, Math.max(0.2, ratio));
      lastRatioRef.current = clamped;
      setSplitRatio(clamped);
    };
    const onMouseUp = () => {
      document.removeEventListener("mousemove", onMouseMove);
      document.removeEventListener("mouseup", onMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
  }, []);

  const toggleCollapse = useCallback(() => {
    if (isCollapsed) {
      setIsCollapsed(false);
      setSplitRatio(lastRatioRef.current);
    } else {
      lastRatioRef.current = splitRatio;
      setIsCollapsed(true);
    }
  }, [isCollapsed, splitRatio]);

  const collapseLeft = isCollapsed
    ? `${SIDEBAR_WIDTH + 14}px`
    : `calc(${SIDEBAR_WIDTH}px + ${splitRatio} * (100vw - ${SIDEBAR_WIDTH}px))`;

  return {
    containerRef,
    splitRatio,
    isCollapsed,
    isDividerHovered,
    setIsDividerHovered,
    handleDividerMouseDown,
    toggleCollapse,
    collapseLeft,
  };
}
