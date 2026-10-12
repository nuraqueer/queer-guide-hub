/** @vitest-environment jsdom */
import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';

const { invoke, toast } = vi.hoisted(() => ({ invoke: vi.fn(), toast: vi.fn() }));
vi.mock('@/hooks/use-toast', () => ({ useToast: () => ({ toast }) }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { functions: { invoke } } }));
import { EventbriteImport } from '../EventbriteImport';

describe('EventbriteImport', () => {
  it('reports a retired endpoint instead of staged success', async () => {
    invoke.mockResolvedValue({
      data: { success: true, skipped: true, reason: 'endpoint_retired_404_no_successor', items: 0 },
      error: null,
    });
    const onImportComplete = vi.fn();
    render(<EventbriteImport onImportComplete={onImportComplete} />);
    fireEvent.click(screen.getByRole('button', { name: 'Import from Eventbrite' }));
    fireEvent.change(screen.getByLabelText('Search Query *'), { target: { value: 'Pride' } });
    fireEvent.click(screen.getByRole('button', { name: 'Import Events' }));
    await waitFor(() =>
      expect(toast).toHaveBeenCalledWith(
        expect.objectContaining({
          title: 'Import failed',
          description: expect.stringContaining('endpoint_retired'),
          variant: 'destructive',
        }),
      ),
    );
    expect(onImportComplete).not.toHaveBeenCalled();
    expect(toast).not.toHaveBeenCalledWith(expect.objectContaining({ title: 'Staged for review' }));
  });
});
