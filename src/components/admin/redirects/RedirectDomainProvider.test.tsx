import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RedirectDomainProvider, type DomainProviderStatus } from './RedirectDomainProvider';
const provider: DomainProviderStatus = {
  state: 'review',
  desired: true,
  cnameTarget: 'links.queer.guide',
  hostnameStatus: null,
  certificateStatus: null,
  certificateReady: false,
  checkedAt: null,
  error: null,
  canConfirmAbsence: false,
  validationRecords: [],
  candidates: [],
};
function show(value?: DomainProviderStatus, configured = true) {
  const act = vi.fn();
  render(
    <RedirectDomainProvider
      hostname="links.example.com"
      verified
      disabled={false}
      connected={!!value?.id}
      pending={false}
      setup={{ configured, cnameTarget: configured ? 'links.queer.guide' : null }}
      provider={value}
      act={act}
    />,
  );
  return act;
}
describe('reviewed hostname provider controls', () => {
  it('requires explicit review before connection and stays disabled when unconfigured', () => {
    const act = show();
    fireEvent.click(screen.getByRole('button', { name: 'Request provider connection' }));
    expect(act).not.toHaveBeenCalled();
    expect(
      screen.getByText(/This can use your configured provider account resources/),
    ).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm provider connection' }));
    expect(act).toHaveBeenCalledWith('/provider/connect', 'POST');
  });
  it('shows provider and certificate activation separately without claiming public routing', () => {
    show(
      {
        ...provider,
        state: 'waiting',
        hostnameStatus: 'active',
        certificateStatus: 'pending_validation',
      },
      false,
    );
    expect(screen.getByText('active')).toBeVisible();
    expect(screen.getByText('pending_validation')).toBeVisible();
    expect(screen.getByText('Not ready')).toBeVisible();
    expect(screen.getByText(/Public branded routing is not available yet/)).toBeVisible();
    expect(screen.getByRole('button', { name: 'Request provider connection' })).toBeDisabled();
  });
  it('reviews the exact candidate and requires an absence attestation for uncertain creates', () => {
    const candidate = '00000000-0000-4000-8000-000000000004';
    const act = show({
      ...provider,
      candidates: [{ id: candidate, hostname: 'links.example.com' }],
      canConfirmAbsence: true,
    });
    fireEvent.click(screen.getByRole('button', { name: 'Review existing hostname' }));
    expect(act).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm provider hostname' }));
    expect(act).toHaveBeenCalledWith('/provider/adopt', 'POST', { candidateId: candidate });
    fireEvent.click(screen.getByRole('button', { name: 'Cancel provider action' }));
    fireEvent.click(screen.getByRole('button', { name: 'Review provider absence' }));
    const confirm = screen.getByRole('button', { name: 'Confirm provider hostname is absent' });
    expect(confirm).toBeDisabled();
    fireEvent.click(
      screen.getByLabelText('I inspected Cloudflare and confirm this hostname is absent'),
    );
    fireEvent.click(confirm);
    expect(act).toHaveBeenCalledWith('/provider/confirm-absence', 'POST', {
      confirmedAbsent: true,
    });
  });
  it('reviews provider disconnection before requesting cleanup', () => {
    const act = show({
      ...provider,
      state: 'ready',
      id: '00000000-0000-4000-8000-000000000004',
      certificateReady: true,
      hostnameStatus: 'active',
      certificateStatus: 'active',
    });
    fireEvent.click(screen.getByRole('button', { name: 'Disconnect provider' }));
    expect(act).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm provider disconnect' }));
    expect(act).toHaveBeenCalledWith('/provider/disconnect', 'POST');
  });
});
