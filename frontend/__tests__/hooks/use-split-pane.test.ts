import { renderHook, act } from '@testing-library/react';
import { useSplitPane } from '@/hooks/use-split-pane';

describe('useSplitPane', () => {
  it('initialises with splitRatio=0.5 and not collapsed', () => {
    const { result } = renderHook(() => useSplitPane());
    expect(result.current.splitRatio).toBe(0.5);
    expect(result.current.isCollapsed).toBe(false);
    expect(result.current.isDividerHovered).toBe(false);
  });

  it('toggleCollapse collapses the panel', () => {
    const { result } = renderHook(() => useSplitPane());
    act(() => { result.current.toggleCollapse(); });
    expect(result.current.isCollapsed).toBe(true);
  });

  it('toggleCollapse a second time restores to previous ratio', () => {
    const { result } = renderHook(() => useSplitPane());

    act(() => { result.current.toggleCollapse(); });
    expect(result.current.isCollapsed).toBe(true);

    act(() => { result.current.toggleCollapse(); });
    expect(result.current.isCollapsed).toBe(false);
    expect(result.current.splitRatio).toBe(0.5);
  });

  it('setIsDividerHovered updates hover state', () => {
    const { result } = renderHook(() => useSplitPane());
    act(() => { result.current.setIsDividerHovered(true); });
    expect(result.current.isDividerHovered).toBe(true);
    act(() => { result.current.setIsDividerHovered(false); });
    expect(result.current.isDividerHovered).toBe(false);
  });

  it('collapseLeft positions at sidebar edge when collapsed', () => {
    const { result } = renderHook(() => useSplitPane());
    act(() => { result.current.toggleCollapse(); });

    expect(result.current.collapseLeft).toBe('234px');
  });

  it('collapseLeft contains splitRatio when not collapsed', () => {
    const { result } = renderHook(() => useSplitPane());
    expect(result.current.collapseLeft).toContain('0.5');
  });
});
