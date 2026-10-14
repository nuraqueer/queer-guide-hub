/**
 * @vitest-environment jsdom
 */
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Loading, LoadingSpinner, PageLoading, InlineLoading } from '../loading';

describe('Loading variants', () => {
  it('Loading renders', () => {
    const { container } = render(<Loading />);
    expect(container.firstChild).toBeTruthy();
  });
  it('LoadingSpinner renders', () => {
    const { container } = render(<LoadingSpinner />);
    expect(container).toBeTruthy();
  });
  it('PageLoading announces its label', () => {
    render(<PageLoading text="Hold on" />);
    expect(screen.getByRole('status', { name: 'Hold on' })).toBeInTheDocument();
  });
  it('InlineLoading renders text', () => {
    render(<InlineLoading text="Wait" />);
    expect(screen.getByText('Wait')).toBeInTheDocument();
  });
});
