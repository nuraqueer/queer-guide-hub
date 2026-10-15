import { useState } from 'react';
import { Button } from '@/components/ui/button';
export interface DomainProviderStatus {
  id?: string | null;
  state: string;
  desired: boolean;
  cnameTarget: string | null;
  hostnameStatus: string | null;
  certificateStatus: string | null;
  certificateReady: boolean;
  checkedAt: string | null;
  error: string | null;
  canConfirmAbsence: boolean;
  canRestartValidation?: boolean;
  validationRestartPending?: boolean;
  validationRestartRequestedAt?: string | null;
  validationRestartStartedAt?: string | null;
  validationRecords: { type: string; name: string; value: string }[];
  candidates: { id: string; hostname: string; createdAt?: string }[];
}
export function RedirectDomainProvider({
  provider,
  setup,
  hostname,
  verified,
  disabled,
  connected,
  pending,
  act,
  routingReady = false,
  routingSeenAt,
  onRoutingChecked,
}: {
  routingReady?: boolean;
  routingSeenAt?: string | null;
  onRoutingChecked?: () => Promise<unknown>;
  provider?: DomainProviderStatus;
  setup?: { configured: boolean; cnameTarget: string | null };
  hostname: string;
  verified: boolean;
  disabled: boolean;
  connected: boolean;
  pending: boolean;
  act: (suffix: string, method: 'POST', body?: Record<string, unknown>) => void;
}) {
  const [checkingRoute, setCheckingRoute] = useState(false);
  const [routingMessage, setRoutingMessage] = useState('');
  const [review, setReview] = useState<'connect' | 'disconnect' | 'absence' | null>(null);
  const [candidate, setCandidate] = useState<string | null>(null);
  const [confirmedAbsent, setConfirmedAbsent] = useState(false);
  const configured = setup?.configured === true;
  const state = provider?.state ?? 'not_requested';
  const cname = provider?.cnameTarget ?? setup?.cnameTarget;
  const canConnect =
    configured && verified && !disabled && !provider?.desired && state !== 'review';
  return (
    <section aria-label={'Provider setup for ' + hostname} className="space-y-4 border-t pt-4">
      <h4 className="font-semibold">Hostname provider and TLS</h4>
      {!configured && (
        <p className="text-sm">
          The hostname provider is not configured for this workspace. DNS ownership checks and
          stored defaults remain available.
        </p>
      )}
      <p className="text-sm">
        Provider work: {state.replaceAll('_', ' ')} ·{' '}
        {provider?.desired ? 'Connection requested' : 'Connection not requested'}
      </p>
      {provider && (
        <dl className="grid gap-2 text-sm sm:grid-cols-2">
          <dt>Hostname validation</dt>
          <dd>{provider.hostnameStatus ?? 'Not checked'}</dd>
          <dt>Certificate validation</dt>
          <dd>{provider.certificateStatus ?? 'Not checked'}</dd>
          <dt>Current certificate checks</dt>
          <dd>{provider.certificateReady ? 'Passed' : 'Not ready'}</dd>
          {provider.checkedAt && (
            <>
              <dt>Last provider check</dt>
              <dd>{new Date(provider.checkedAt).toLocaleString()}</dd>
            </>
          )}
          {provider.id && (
            <>
              <dt>Provider reference</dt>
              <dd className="break-all">{provider.id}</dd>
            </>
          )}
        </dl>
      )}
      <section aria-label="Branded routing" className="space-y-2">
        <p className="text-sm">Branded routing: {routingReady ? 'Ready' : 'Not verified'}</p>
        {routingSeenAt && (
          <p className="text-sm text-muted-foreground">
            Last route check: {new Date(routingSeenAt).toLocaleString()}
          </p>
        )}
        <p className="text-sm text-muted-foreground">
          Check routing after the certificate is active and your hostname points to the configured
          CNAME target.
        </p>
        <Button
          type="button"
          variant="outline"
          disabled={
            pending || checkingRoute || !verified || disabled || !provider?.certificateReady
          }
          onClick={async () => {
            setCheckingRoute(true);
            setRoutingMessage('');
            try {
              const response = await fetch('https://' + hostname + '/.well-known/qg-redirect', {
                method: 'GET',
                credentials: 'omit',
                referrerPolicy: 'no-referrer',
                cache: 'no-store',
                redirect: 'error',
                signal: AbortSignal.timeout(8000),
              });
              if (
                !response.ok ||
                !response.headers.get('Content-Type')?.startsWith('application/json')
              )
                throw new Error('Routing check failed');
              const reader = response.body?.getReader();
              if (!reader) throw new Error('Routing check failed');
              let body = '';
              let bytes = 0;
              const decoder = new TextDecoder();
              for (;;) {
                const { value, done } = await reader.read();
                if (done) break;
                bytes += value.length;
                if (bytes > 4096) {
                  await reader.cancel();
                  throw new Error('Routing check failed');
                }
                body += decoder.decode(value, { stream: true });
              }
              const result = JSON.parse(body + decoder.decode());
              if (result.ready !== true || result.protocol !== 1)
                throw new Error('Routing check failed');
              await onRoutingChecked?.();
              setRoutingMessage('Routing check received. Current status refreshed.');
            } catch {
              setRoutingMessage(
                'Could not verify routing. Check DNS, certificate status and the branded routing service, then try again.',
              );
            } finally {
              setCheckingRoute(false);
            }
          }}
        >
          {checkingRoute ? 'Checking routing…' : 'Check branded routing'}
        </Button>
        {routingMessage && (
          <p role="status" className="text-sm">
            {routingMessage}
          </p>
        )}
      </section>
      {provider?.error && (
        <p role="alert" className="text-sm">
          {provider.error}
        </p>
      )}
      {cname && (
        <div className="space-y-2 text-sm">
          <p>
            Routing target for setup: <span className="break-all">{cname}</span>. Domain:{' '}
            <span className="break-all">{hostname}</span>.
          </p>
          <p>
            Complete provider validation and public routing setup before moving live traffic to this
            target. This panel does not change DNS records.
          </p>
        </div>
      )}
      {!!provider?.validationRecords.length && (
        <div className="space-y-2 text-sm">
          <p>Provider TXT validation records</p>
          <ul className="space-y-2">
            {provider.validationRecords.map((record, index) => (
              <li key={record.name + index} className="break-all">
                {record.type} · {record.name} · {record.value}
              </li>
            ))}
          </ul>
        </div>
      )}
      <div className="flex flex-wrap gap-2">
        <Button
          variant="outline"
          disabled={!canConnect || pending}
          onClick={() => {
            setCandidate(null);
            setReview('connect');
          }}
        >
          Request provider connection
        </Button>
        {state !== 'not_requested' && (
          <Button
            variant="outline"
            disabled={!configured || pending}
            onClick={() => act('/provider/refresh', 'POST')}
          >
            Refresh provider checks
          </Button>
        )}
        {connected && provider?.desired && (
          <Button
            variant="outline"
            disabled={
              !configured || pending || !verified || disabled || !provider.canRestartValidation
            }
            onClick={() => act('/provider/restart-validation', 'POST')}
          >
            Restart hostname and TLS validation
          </Button>
        )}
        {(provider?.desired || connected || state === 'review') && (
          <Button
            variant="outline"
            disabled={!configured || pending}
            onClick={() => {
              setCandidate(null);
              setReview('disconnect');
            }}
          >
            Disconnect provider
          </Button>
        )}
      </div>
      {provider?.validationRestartRequestedAt && (
        <p role="status" className="text-sm">
          {provider.validationRestartPending
            ? 'Validation restart queued. The provider worker will recheck ownership before sending it.'
            : provider.validationRestartStartedAt
              ? 'Validation restart attempted. Refresh provider checks to see the current result.'
              : 'Validation restart superseded. Refresh provider checks before requesting it again.'}{' '}
          Requests are limited to once every five minutes. An interrupted request may need another
          attempt after reviewing status.
        </p>
      )}
      {state === 'review' && (
        <div className="space-y-2 text-sm">
          <p>
            Existing or uncertain provider creation requires review. Creating another hostname is
            blocked.
          </p>
          {provider?.candidates.map((item) => (
            <div key={item.id} className="space-y-2 border-t pt-2">
              <p className="break-all">
                {item.hostname} · {item.id}
                {item.createdAt ? ' · Created ' + new Date(item.createdAt).toLocaleString() : ''}
              </p>
              <Button
                variant="outline"
                disabled={!configured || pending || (!!provider.desired && (!verified || disabled))}
                onClick={() => {
                  setReview(null);
                  setCandidate(item.id);
                }}
              >
                {provider.desired ? 'Review existing hostname' : 'Review hostname for cleanup'}
              </Button>
            </div>
          ))}
          {provider?.candidates.length === 0 && (
            <p>
              Cloudflare returned zero matching hostnames. An uncertain creation still needs review.
              Wait at least 15 minutes, inspect Cloudflare, then refresh these checks before
              confirming absence.
            </p>
          )}
          {provider?.canConfirmAbsence && (
            <Button
              variant="outline"
              disabled={!configured || pending}
              onClick={() => {
                setCandidate(null);
                setReview('absence');
              }}
            >
              Review provider absence
            </Button>
          )}
        </div>
      )}
      {(review || candidate) && (
        <div className="space-y-2 border p-4">
          <p className="text-sm">
            {candidate
              ? provider?.desired
                ? 'Attach this exact existing provider hostname to the workspace? Fresh ownership proof and a matching provider response are required.'
                : 'Attach this exact hostname for cleanup? It will stay unavailable and the worker will remove it.'
              : review === 'connect'
                ? 'Request a Cloudflare hostname and certificate for this verified domain? This can use your configured provider account resources. It does not activate public routing.'
                : review === 'disconnect'
                  ? 'Disable certificate readiness immediately and remove the known provider hostname in the background? Uncertain creation must be reconciled before the registration can be removed.'
                  : 'Confirm the provider hostname is absent? This clears the uncertain create intent and leaves the connection disconnected.'}
          </p>
          {candidate && (
            <p className="break-all text-sm">
              {hostname} · {candidate}
            </p>
          )}
          {review === 'absence' && (
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={confirmedAbsent}
                onChange={(event) => setConfirmedAbsent(event.target.checked)}
              />
              I inspected Cloudflare and confirm this hostname is absent
            </label>
          )}
          <div className="flex flex-wrap gap-2">
            <Button
              disabled={pending || (review === 'absence' && !confirmedAbsent)}
              onClick={() => {
                if (candidate) act('/provider/adopt', 'POST', { candidateId: candidate });
                else if (review === 'absence')
                  act('/provider/confirm-absence', 'POST', { confirmedAbsent: true });
                else act('/provider/' + review, 'POST');
              }}
            >
              {candidate
                ? 'Confirm provider hostname'
                : review === 'connect'
                  ? 'Confirm provider connection'
                  : review === 'disconnect'
                    ? 'Confirm provider disconnect'
                    : 'Confirm provider hostname is absent'}
            </Button>
            <Button
              variant="outline"
              disabled={pending}
              onClick={() => {
                setReview(null);
                setCandidate(null);
                setConfirmedAbsent(false);
              }}
            >
              Cancel provider action
            </Button>
          </div>
        </div>
      )}
    </section>
  );
}
