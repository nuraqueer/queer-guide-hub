import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectLinkBuilder } from './RedirectLinkBuilder';
import type { RedirectWorkspace } from '@/hooks/useRedirectWorkspace';
const mocks = vi.hoisted(() => ({
  create: vi.fn(),
  workspace: {
    data: undefined as RedirectWorkspace | undefined,
    resource: { mutateAsync: vi.fn(), isError: false },
    createLink: { mutateAsync: vi.fn() },
  },
}));
vi.mock('@/hooks/useRedirectWorkspace', () => ({
  useRedirectWorkspace: () => mocks.workspace,
}));
vi.mock('@/hooks/useRedirects', () => ({ useRedirects: () => ({ createRedirect: mocks.create }) }));
vi.mock('./RedirectQrDialog', () => ({
  QrExport: ({ url }: { url: string }) => <p>Saved QR URL: {url}</p>,
}));
beforeEach(() => {
  vi.clearAllMocks();
  mocks.workspace.data = undefined;
});
function show() {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <RedirectLinkBuilder
        onClose={vi.fn()}
        seed={{
          id: 'city',
          source: '/city/old',
          target: '/city/zurich?view=map#places',
          origin: 'city_slug_redirects',
          kind: 'Automatic',
          statusCode: 301,
          state: 'Enabled',
          updatedAt: null,
          campaign: { utm_source: 'poster' },
          prefill: { audience: 'friends & family' },
        }}
      />
    </QueryClientProvider>,
  );
}
describe('tracked link creation', () => {
  it('prefills the selected destination/settings, saves the encoded destination, and generates the persisted short URL', async () => {
    mocks.create.mockResolvedValue({ slug: 'zurich-campaign' });
    show();
    expect(screen.getByLabelText('Destination')).toHaveValue('/city/zurich?view=map#places');
    expect(screen.getByLabelText('Source')).toHaveValue('poster');
    expect(screen.getByLabelText('Parameter value')).toHaveValue('friends & family');
    fireEvent.change(screen.getByLabelText('Short-link slug'), {
      target: { value: ' zurich-campaign ' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Create tracked link' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledOnce());
    expect(mocks.create.mock.calls[0][0].slug).toBe('zurich-campaign');
    const target = new URL(mocks.create.mock.calls[0][0].target, 'https://queer.guide');
    expect(target.searchParams.get('audience')).toBe('friends & family');
    expect(target.searchParams.get('utm_source')).toBe('poster');
    expect(target.hash).toBe('#places');
    expect(
      await screen.findByText('Saved QR URL: https://queer.guide/go/zurich-campaign'),
    ).toBeVisible();
  });
  it('generates a random slug while preserving destination and campaign fields', () => {
    show();
    fireEvent.click(screen.getByRole('button', { name: 'Generate random slug' }));
    expect((screen.getByLabelText('Short-link slug') as HTMLInputElement).value).toMatch(
      /^[a-f0-9]{12}$/,
    );
    expect(screen.getByLabelText('Destination')).toHaveValue('/city/zurich?view=map#places');
    expect(screen.getByLabelText('Source')).toHaveValue('poster');
  });
  it('keeps entered fields and reports a failed save without displaying an unsaved QR link', async () => {
    mocks.create.mockResolvedValue(null);
    show();
    fireEvent.click(screen.getByRole('button', { name: 'Create tracked link' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not create the link');
    expect(screen.getByLabelText('Destination')).toHaveValue('/city/zurich?view=map#places');
    expect(screen.queryByText(/Saved QR URL/)).toBeNull();
  });
});

describe('shared campaign workspace', () => {
  it('applies shared templates and creates folder/tag assignments through one atomic operation', async () => {
    mocks.workspace.data = {
      folders: [{ id: 'folder', name: 'Pride', description: '' }],
      tags: [{ id: 'tag', name: 'Print', color: 'blue' }],
      templates: [
        { id: 'template', name: 'Poster', parameters: { utm_source: 'qr', ref: 'team' } },
      ],
      metadata: new Map([
        ['city', { redirect_key: 'city', folder_id: 'folder', tagIds: ['tag'], comment: '' }],
      ]),
    };
    mocks.workspace.createLink.mutateAsync.mockResolvedValue({
      id: 'created',
      slug: 'zurich-campaign',
    });
    show();
    expect(screen.getByRole('combobox', { name: 'New link folder' })).toHaveValue('folder');
    expect(screen.getByRole('checkbox', { name: 'Print' })).toBeChecked();
    fireEvent.change(screen.getByRole('combobox', { name: 'Apply UTM template' }), {
      target: { value: 'template' },
    });
    expect(screen.getByLabelText('Source')).toHaveValue('qr');
    expect(screen.getByLabelText('Referral')).toHaveValue('team');
    fireEvent.click(screen.getByRole('button', { name: 'Create tracked link' }));
    await waitFor(() => expect(mocks.workspace.createLink.mutateAsync).toHaveBeenCalledOnce());
    expect(mocks.create).not.toHaveBeenCalled();
    expect(mocks.workspace.createLink.mutateAsync).toHaveBeenCalledWith(
      expect.objectContaining({ folderId: 'folder', tagIds: ['tag'] }),
    );
    expect(
      await screen.findByText('Saved QR URL: https://queer.guide/go/zurich-campaign'),
    ).toBeVisible();
  });
});
