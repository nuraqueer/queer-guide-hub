/**
 * @vitest-environment jsdom
 */
import { describe, it, expect, vi } from 'vitest';
import { fireEvent, render as rtlRender, screen } from '@testing-library/react';

const { setField } = vi.hoisted(() => ({ setField: vi.fn() }));

vi.mock('../RichTextEditor', () => ({
  RichTextEditor: ({
    value,
    onChange,
    editable,
  }: {
    value: string;
    onChange: (json: Record<string, unknown>, html: string) => void;
    editable: boolean;
  }) => (
    <textarea
      aria-label="Page main text editor"
      value={value}
      disabled={!editable}
      onChange={(event) => onChange({ type: 'doc' }, event.target.value)}
    />
  ),
}));

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter } from 'react-router';
import { TooltipProvider } from '@/components/ui/tooltip';
const render = (ui: React.ReactNode) =>
  rtlRender(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter>
        <TooltipProvider>{ui}</TooltipProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  );

vi.mock('@/hooks/useVenueOrganisation', () => ({ useVenueOrganisation: () => ({ data: null }) }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: 'u1' } }) }));
vi.mock('@/hooks/useCMSWorkflow', () => ({
  useCMSWorkflow: () => ({
    metadata: null,
    loading: false,
    transition: vi.fn(),
    setReviewLevel: vi.fn(),
  }),
}));
vi.mock('@/hooks/useCMSMedia', () => ({
  useCMSMedia: () => ({
    getAttachments: vi.fn().mockResolvedValue([]),
    attachMedia: vi.fn(),
    detachMedia: vi.fn(),
  }),
}));
vi.mock('@/hooks/useContentRevisions', () => ({
  useContentRevisions: () => ({
    revisions: [],
    loading: false,
    load: vi.fn(),
    revertFields: vi.fn(),
  }),
  revisionDiffs: () => [],
}));
vi.mock('@/components/cms/media/MediaPickerDialog', () => ({ default: () => null }));
vi.mock('../EditorSidebar', () => ({ EditorSidebar: () => null }));
vi.mock('@/hooks/useCMSEditor', () => ({
  useCMSEditor: () => ({
    state: {
      data: { body_html: '<p>Existing page text</p>' },
      originalData: {},
      isDirty: false,
      itemId: null,
      errors: {},
      isSaving: false,
      isLoading: false,
      activeGroup: 'basic',
    },
    setField,
    setFields: vi.fn(),
    save: vi.fn(),
    reset: vi.fn(),
    refresh: vi.fn(),
    setActiveGroup: vi.fn(),
    updateMetadata: vi.fn(),
    contentType: null,
    loading: false,
    onChange: vi.fn(),
    onSave: vi.fn(),
    onReset: vi.fn(),
    metadata: null,
    onUpdateMetadata: vi.fn(),
  }),
}));

import { CMSEditorLayout } from '../CMSEditorLayout';

describe('CMSEditorLayout', () => {
  it('renders', () => {
    const { container } = render(
      <CMSEditorLayout contentType="venues" itemId={null} onClose={vi.fn()} onSaved={vi.fn()} />,
    );
    expect(container).toBeTruthy();
  });

  it('loads page main text and binds rich-text edits to the saved HTML field', async () => {
    render(<CMSEditorLayout contentType="cms_pages" itemId={null} onClose={vi.fn()} />);

    const editor = await screen.findByRole('textbox', { name: 'Page main text editor' });
    expect(editor).toHaveValue('<p>Existing page text</p>');
    expect(editor).toBeEnabled();

    fireEvent.change(editor, { target: { value: '<p>Updated page text</p>' } });
    expect(setField).toHaveBeenCalledWith('body_html', '<p>Updated page text</p>');
  });
});
