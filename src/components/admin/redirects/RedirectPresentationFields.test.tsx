import { useState } from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectPresentationFields } from './RedirectPresentationFields';
import type { LinkPolicy } from '../../../../supabase/functions/_shared/link-policy';
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), prepare: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
vi.mock('@/lib/redirects/previewImage', () => ({ preparePreviewImage: mocks.prepare }));
function Harness() {
  const [policy, setPolicy] = useState<LinkPolicy>({});
  return (
    <>
      <RedirectPresentationFields
        id="fixture"
        policy={policy}
        onChange={setPolicy}
        onUploading={() => {}}
      />
      <button onClick={() => setPolicy((current) => ({ ...current, track_conversions: true }))}>
        Enable attribution elsewhere
      </button>
      <output aria-label="Saved policy">{JSON.stringify(policy)}</output>
    </>
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.prepare.mockResolvedValue('fixture-image');
});
describe('preview and cloaking editor', () => {
  it('generates a reviewable draft while retaining other policy fields', async () => {
    mocks.invoke.mockResolvedValue({
      data: { title: 'Community events', description: 'Explore local events.' },
      error: null,
    });
    render(<Harness />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Custom social preview' }));
    fireEvent.click(screen.getByRole('button', { name: 'Enable attribution elsewhere' }));
    fireEvent.click(screen.getByRole('button', { name: 'Generate title and description' }));
    await waitFor(() =>
      expect(screen.getByLabelText('Preview title')).toHaveValue('Community events'),
    );
    expect(mocks.invoke).toHaveBeenCalledWith('redirect-api/links/fixture/preview-generate', {
      body: {},
    });
    expect(screen.getByLabelText('Saved policy')).toHaveTextContent('"track_conversions":true');
    expect(screen.getByText(/Review the draft, then Save/)).toBeInTheDocument();
  });
  it('keeps manual text when generation fails', async () => {
    mocks.invoke.mockResolvedValue({
      data: { error: 'Preview generation is not configured' },
      error: null,
    });
    render(<Harness />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Custom social preview' }));
    fireEvent.change(screen.getByLabelText('Preview title'), { target: { value: 'Manual title' } });
    fireEvent.click(screen.getByRole('button', { name: 'Generate title and description' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('not configured');
    expect(screen.getByLabelText('Preview title')).toHaveValue('Manual title');
  });
  it('edits bounded metadata and independently enables framing', () => {
    render(<Harness />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Custom social preview' }));
    fireEvent.change(screen.getByLabelText('Preview title'), { target: { value: 'Community' } });
    fireEvent.change(screen.getByLabelText('Preview description'), {
      target: { value: 'Join us' },
    });
    expect(screen.getByLabelText('Preview title')).toHaveAttribute('maxlength', '120');
    expect(screen.getByLabelText('Preview description')).toHaveAttribute('maxlength', '240');
    fireEvent.click(
      screen.getByRole('checkbox', {
        name: 'Keep the short URL while showing the destination in a frame',
      }),
    );
    expect(screen.getByLabelText('Saved policy')).toHaveTextContent('"cloaked":true');
    fireEvent.click(screen.getByRole('checkbox', { name: 'Custom social preview' }));
    expect(screen.getByLabelText('Saved policy')).not.toHaveTextContent('"preview"');
    expect(screen.getByLabelText('Saved policy')).toHaveTextContent('"cloaked":true');
  });
  it('merges uploaded artwork without erasing concurrent policy edits and supports removal', async () => {
    let finish!: (value: unknown) => void;
    mocks.invoke.mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    render(<Harness />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Custom social preview' }));
    fireEvent.change(screen.getByLabelText('Upload artwork'), {
      target: { files: [new File(['fixture'], 'art.png', { type: 'image/png' })] },
    });
    await waitFor(() => expect(mocks.invoke).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: 'Enable attribution elsewhere' }));
    finish({ data: { image: 'https://example.com/art.png' }, error: null });
    expect(await screen.findByAltText('Social preview artwork')).toHaveAttribute(
      'src',
      'https://example.com/art.png',
    );
    expect(screen.getByLabelText('Saved policy')).toHaveTextContent('"track_conversions":true');
    expect(screen.getByText(/public asset URL remains available/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Remove preview image' }));
    expect(screen.queryByAltText('Social preview artwork')).toBeNull();
  });
});
