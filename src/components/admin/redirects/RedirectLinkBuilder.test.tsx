import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectLinkBuilder } from './RedirectLinkBuilder';
import type { RedirectWorkspace } from '@/hooks/useRedirectWorkspace';
const mocks = vi.hoisted(() => ({
  create: vi.fn(),
  choices: {
    data: [] as Array<{ id: string; hostname: string }>,
    count: 0,
    nextCursor: null,
    primaryDomainId: null as string | null,
    primaryUnavailable: false,
  },
  workspace: {
    data: undefined as RedirectWorkspace | undefined,
    resource: { mutateAsync: vi.fn(), isError: false },
    createLink: { mutateAsync: vi.fn() },
  },
}));
vi.mock('@/hooks/useRedirectWorkspace', () => ({
  useRedirectWorkspace: () => mocks.workspace,
}));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: 'owner' } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({
  memberRedirectApi: async (_path: string, method: string, body: unknown) => {
    if (method === 'GET') return mocks.choices;
    const result = await mocks.create(body);
    return result
      ? {
          link: { ...result, shortUrl: result.shortUrl ?? 'https://queer.guide/go/' + result.slug },
        }
      : null;
  },
}));
vi.mock('./RedirectQrDialog', () => ({
  QrExport: ({ url }: { url: string }) => <p>Saved QR URL: {url}</p>,
}));
beforeEach(() => {
  vi.clearAllMocks();
  mocks.workspace.data = undefined;
  mocks.choices = {
    data: [],
    count: 0,
    nextCursor: null,
    primaryDomainId: null,
    primaryUnavailable: false,
  };
  mocks.create.mockResolvedValue({ slug: 'zurich-campaign' });
});
function show() {
  const client = new QueryClient();
  return {
    client,
    ...render(
      <QueryClientProvider client={client}>
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
    ),
  };
}
describe('tracked link creation', () => {
  it('does not visually fall back when an explicitly selected domain disappears on refresh', async () => {
    mocks.choices = {
      data: [{ id: 'domain-a', hostname: 'links.community.com' }],
      count: 1,
      nextCursor: null,
      primaryDomainId: null,
      primaryUnavailable: false,
    };
    const { client } = show();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toBeEnabled());
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: 'domain-a' } });
    mocks.choices = { ...mocks.choices, data: [], count: 0 };
    await client.invalidateQueries({ queryKey: ['redirect-domain-choices', 'owner'] });
    expect(
      await screen.findByText(
        'The selected domain is unavailable. Choose another domain to continue.',
      ),
    ).toBeVisible();
    expect(screen.getByLabelText('Short-link domain')).toHaveValue('domain-a');
    expect(screen.getByRole('button', { name: 'Create tracked link' })).toBeDisabled();
    expect(mocks.create).not.toHaveBeenCalled();
  });
  it('starts with the ready primary domain and uses the persisted canonical URL', async () => {
    mocks.choices = {
      data: [{ id: 'domain-a', hostname: 'links.community.com' }],
      count: 1,
      nextCursor: null,
      primaryDomainId: 'domain-a',
      primaryUnavailable: false,
    };
    mocks.create.mockResolvedValue({
      slug: 'server-slug',
      shortUrl: 'https://links.community.com/server-slug',
    });
    show();
    await waitFor(() => expect(screen.getByLabelText('Short-link domain')).toHaveValue('domain-a'));
    fireEvent.click(screen.getByRole('button', { name: 'Create tracked link' }));
    await waitFor(() =>
      expect(mocks.create).toHaveBeenCalledWith(expect.objectContaining({ domainId: 'domain-a' })),
    );
    expect(
      await screen.findByText('Saved QR URL: https://links.community.com/server-slug'),
    ).toBeVisible();
  });
  it('requires an explicit available selection if the primary becomes unavailable', async () => {
    mocks.choices = {
      data: [],
      count: 0,
      nextCursor: null,
      primaryDomainId: 'lost-domain',
      primaryUnavailable: true,
    };
    show();
    expect(
      await screen.findByText(
        'The primary domain is unavailable. Choose another domain to continue.',
      ),
    ).toBeVisible();
    expect(screen.getByRole('button', { name: 'Create tracked link' })).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Short-link domain'), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create tracked link' }));
    await waitFor(() =>
      expect(mocks.create).toHaveBeenCalledWith(expect.objectContaining({ domainId: null })),
    );
  });
  it('prefills the selected destination/settings, saves the encoded destination, and generates the persisted short URL', async () => {
    mocks.create.mockResolvedValue({ slug: 'zurich-campaign' });
    show();
    expect(screen.getByLabelText('Destination')).toHaveValue('/city/zurich?view=map#places');
    expect(screen.getByLabelText('Source')).toHaveValue('poster');
    expect(screen.getByLabelText('Parameter value')).toHaveValue('friends & family');
    fireEvent.change(screen.getByLabelText('Short-link slug'), {
      target: { value: ' zurich-campaign ' },
    });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create tracked link' })).toBeEnabled(),
    );
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
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create tracked link' })).toBeEnabled(),
    );
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
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create tracked link' })).toBeEnabled(),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Create tracked link' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledOnce());
    expect(mocks.workspace.createLink.mutateAsync).not.toHaveBeenCalled();
    expect(mocks.create).toHaveBeenCalledWith(
      expect.objectContaining({ folderId: 'folder', tagIds: ['tag'] }),
    );
    expect(
      await screen.findByText('Saved QR URL: https://queer.guide/go/zurich-campaign'),
    ).toBeVisible();
  });
});
