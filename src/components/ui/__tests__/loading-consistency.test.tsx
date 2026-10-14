/** @vitest-environment jsdom */
import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Loading, InlineLoading } from '../loading';
import { LoadingRegion } from '../loading-region';
import { PageLoadingState } from '@/components/layout/PageLoadingState';
import {
  AdminCardSkeleton,
  AdminTableSkeleton,
  AdminTableRowSkeleton,
  AdminTextSkeleton,
} from '@/components/admin/primitives/AdminLoading';

const variants = [
  ['public indicator', Loading],
  ['public inline indicator', InlineLoading],
  ['public page', PageLoadingState],
  ['admin card', AdminCardSkeleton],
  ['admin table', AdminTableSkeleton],
  ['admin text', AdminTextSkeleton],
] as const;

describe('shared public and admin loading behavior', () => {
  afterEach(() => vi.useRealTimers());

  it.each(variants)(
    '%s reserves layout, delays visual feedback, then explains a slow request',
    (_, Component) => {
      vi.useFakeTimers();
      const { container } = render(<Component />);
      const status = screen.getByRole('status');
      expect(status).toHaveClass('invisible');
      act(() => void vi.advanceTimersByTime(399));
      expect(status).toHaveClass('invisible');
      act(() => void vi.advanceTimersByTime(1));
      expect(status).not.toHaveClass('invisible');
      expect(container.querySelector('[stroke="hsl(var(--track-pink))"]')).toBeNull();
      act(() => void vi.advanceTimersByTime(7600));
      expect(screen.getByText(/taking longer than expected/i)).toBeInTheDocument();
      expect(container.querySelector('.animate-pulse, .track-loader')).toBeNull();
      expect(screen.getAllByRole('status')).toHaveLength(1);
    },
  );

  it('offers an actual retry callback in the shared slow state', () => {
    vi.useFakeTimers();
    const retry = vi.fn();
    render(
      <LoadingRegion label="Loading records" onRetry={retry}>
        <div>Placeholder</div>
      </LoadingRegion>,
    );
    act(() => void vi.advanceTimersByTime(8000));
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(retry).toHaveBeenCalledOnce();
  });

  it('keeps table loading markup valid during both phases', () => {
    vi.useFakeTimers();
    const { container } = render(
      <table>
        <tbody>
          <AdminTableRowSkeleton columns={4} rows={2} />
        </tbody>
      </table>,
    );
    expect(container.querySelectorAll('tbody > tr')).toHaveLength(2);
    expect(container.querySelector('tr')).toHaveClass('invisible');
    act(() => void vi.advanceTimersByTime(400));
    expect(container.querySelector('tr')).not.toHaveClass('invisible');
    act(() => void vi.advanceTimersByTime(7600));
    expect(container.querySelectorAll('tbody > tr')).toHaveLength(1);
    expect(container.querySelector('td')).toHaveAttribute('colspan', '4');
    expect(screen.getByRole('status')).toHaveTextContent(/taking longer than expected/i);
  });
});
