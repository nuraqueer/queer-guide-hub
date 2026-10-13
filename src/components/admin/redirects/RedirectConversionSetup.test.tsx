import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectConversionSetup } from './RedirectConversionSetup';
const mocks = vi.hoisted(() => ({ create: vi.fn(), revoke: vi.fn() }));
vi.mock('@/hooks/useRedirectCredentials', () => ({
  useRedirectCredentials: () => ({
    data: [
      {
        id: 'credential',
        name: 'Billing',
        prefix: 'fixture',
        redirect_ids: null,
        created_at: '2026-10-13T09:00:00Z',
        expires_at: '2030-10-13T09:00:00Z',
        last_used_at: null,
        revoked_at: null,
      },
    ],
    isPending: false,
    isError: false,
    create: { mutateAsync: mocks.create, isPending: false, isError: false, reset: vi.fn() },
    revoke: { mutateAsync: mocks.revoke, isPending: false, isError: false },
  }),
}));
const links = [
  {
    id: 'link',
    manualId: '00000000-0000-4000-8000-000000000001',
    source: '/go/pride',
    target: '/events',
    kind: 'Manual' as const,
    origin: 'redirects',
    state: 'Enabled' as const,
    statusCode: 302,
    updatedAt: null,
  },
];
beforeEach(() => {
  vi.clearAllMocks();
  mocks.create.mockResolvedValue({ secret: 'qg_redirect_fixture' });
  mocks.revoke.mockResolvedValue({});
});
describe('conversion credential setup', () => {
  it('requires explicit link selection for scoped credentials and shows the created secret once', async () => {
    render(<RedirectConversionSetup links={links} onClose={vi.fn()} />);
    fireEvent.change(screen.getByLabelText('Credential name'), { target: { value: 'Checkout' } });
    fireEvent.click(screen.getByRole('checkbox', { name: 'Limit to selected managed links' }));
    expect(screen.getByRole('button', { name: 'Create server credential' })).toBeDisabled();
    fireEvent.click(screen.getByRole('checkbox', { name: '/go/pride' }));
    fireEvent.click(screen.getByRole('button', { name: 'Create server credential' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalled());
    expect(mocks.create.mock.calls[0][0]).toMatchObject({
      name: 'Checkout',
      redirectIds: [links[0].manualId],
    });
    expect(
      await screen.findByLabelText('New server credential', { selector: 'input' }),
    ).toHaveValue('qg_redirect_fixture');
    fireEvent.click(screen.getByRole('button', { name: 'Done' }));
    expect(screen.queryByLabelText('New server credential', { selector: 'input' })).toBeNull();
  });
  it('creates management-only credentials and explains selected-link creation limits', async () => {
    render(<RedirectConversionSetup links={links} onClose={vi.fn()} />);
    fireEvent.change(screen.getByLabelText('Credential name'), {
      target: { value: 'Link automation' },
    });
    fireEvent.click(screen.getByRole('checkbox', { name: 'Write conversions' }));
    expect(screen.getByRole('button', { name: 'Create server credential' })).toBeDisabled();
    fireEvent.click(screen.getByRole('checkbox', { name: 'Create, edit and delete links' }));
    expect(screen.getByRole('button', { name: 'Create server credential' })).toBeEnabled();
    expect(screen.getByText(/Creating new links requires workspace-wide permission/)).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Create server credential' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalled());
    expect(mocks.create.mock.calls[0][0].scopes).toEqual(['links:write']);
  });
  it('requires confirmation inside the app before revocation', async () => {
    render(<RedirectConversionSetup links={links} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }));
    expect(mocks.revoke).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm revoke' }));
    await waitFor(() => expect(mocks.revoke).toHaveBeenCalledWith('credential'));
  });
});
