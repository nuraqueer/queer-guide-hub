import { RedirectQrStyleSettings } from './RedirectQrStyleSettings';
import { RedirectPrimaryDomain } from './RedirectPrimaryDomain';
import { RedirectDomainProvider, type DomainProviderStatus } from './RedirectDomainProvider';
import { useState } from 'react';
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '@/hooks/useAuth';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
interface Domain {
  id: string;
  hostname: string;
  version: string;
  disabled: boolean;
  ownershipState: 'pending' | 'verified' | 'lost';
  ownershipVerified: boolean;
  verifiedUntil: string | null;
  lastCheck: string | null;
  providerConnected: boolean;
  routingReady?: boolean;
  routingSeenAt?: string | null;
  provider?: DomainProviderStatus;
  rootUrl: string | null;
  notFoundUrl: string | null;
  expiredUrl: string | null;
  verification: { type: string; name: string; value: string };
}
export function RedirectDomains() {
  const { user } = useAuth();
  return user ? <DomainRegistry key={user.id} accountId={user.id} /> : null;
}
function DomainRegistry({ accountId }: { accountId: string }) {
  const client = useQueryClient();
  const [hostname, setHostname] = useState('');
  const [message, setMessage] = useState('');
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const key = ['redirect-domains', accountId];
  const query = useInfiniteQuery({
    queryKey: key,
    initialPageParam: null as string | null,
    queryFn: ({ pageParam }) =>
      memberRedirectApi<{
        data: Domain[];
        count: number;
        nextCursor: string | null;
        providerSetup?: { configured: boolean; cnameTarget: string | null };
      }>('/domains?limit=50' + (pageParam ? '&cursor=' + pageParam : '')),
    getNextPageParam: (page) => page.nextCursor ?? undefined,
    retry: false,
    refetchOnWindowFocus: false,
  });
  const mutation = useMutation({
    mutationFn: ({
      path,
      method,
      body,
    }: {
      path: string;
      method: 'POST' | 'PATCH' | 'DELETE';
      body: Record<string, unknown>;
    }) => memberRedirectApi<Domain>(path, method, body),
    onSuccess: async (_, variables) => {
      if (variables.path === '/domains') setHostname('');
      setMessage(
        'Domain settings updated. Ownership verification alone does not activate short links.',
      );
      await Promise.all([
        client.invalidateQueries({ queryKey: key }),
        client.invalidateQueries({ queryKey: ['redirect-domain-choices'] }),
        client.invalidateQueries({ queryKey: ['redirect-domain-preference'] }),
      ]);
    },
  });
  return (
    <section aria-label="Custom domains" className="space-y-4 border-t pt-4">
      <h3 className="text-title font-sans font-bold">Custom domains</h3>
      <p className="text-sm">
        Register a domain you control and verify its TXT record. Ownership, TLS and branded routing
        are separate requirements. Provider connections run in the background. Check branded routing
        once DNS and the certificate are ready.
      </p>
      <RedirectPrimaryDomain userId={accountId} />
      <form
        className="space-y-2"
        onSubmit={(event) => {
          event.preventDefault();
          setMessage('');
          mutation.mutate({
            path: '/domains',
            method: 'POST',
            body: { hostname: hostname.trim() },
          });
        }}
      >
        <Label htmlFor="redirect-domain-hostname">Domain hostname</Label>
        <Input
          id="redirect-domain-hostname"
          value={hostname}
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          placeholder="links.yourdomain.com"
          maxLength={253}
          onChange={(event) => setHostname(event.target.value)}
          disabled={mutation.isPending}
          required
        />
        <Button type="submit" disabled={mutation.isPending || !hostname.trim()}>
          Register domain
        </Button>
      </form>
      {query.isPending && <p role="status">Loading domains…</p>}
      {(query.isError || mutation.isError) && (
        <p role="alert">{mutation.error?.message ?? query.error?.message}</p>
      )}
      {message && (
        <p role="status" className="text-sm">
          {message}
        </p>
      )}
      <Button
        variant="outline"
        disabled={query.isFetching || mutation.isPending}
        onClick={() => void query.refetch()}
      >
        Refresh domains
      </Button>
      {query.data && <p className="text-sm">{query.data.pages[0].count} registered domains</p>}
      <ul className="space-y-4">
        {query.data?.pages
          .flatMap((page) => page.data)
          .map((domain) => (
            <DomainRow
              key={domain.id + domain.version}
              domain={domain}
              pending={mutation.isPending}
              setup={query.data?.pages[0].providerSetup}
              onRoutingChecked={() =>
                Promise.all([
                  client.invalidateQueries({ queryKey: key }),
                  client.invalidateQueries({ queryKey: ['redirect-domain-choices'] }),
                  client.invalidateQueries({ queryKey: ['redirect-domain-preference'] }),
                ])
              }
              expanded={expanded.has(domain.id)}
              onExpand={(open) =>
                setExpanded((current) => {
                  if (current.has(domain.id) === open) return current;
                  const next = new Set(current);
                  if (open) next.add(domain.id);
                  else next.delete(domain.id);
                  return next;
                })
              }
              act={(suffix, method, body) => {
                setMessage('');
                mutation.mutate({
                  path: '/domains/' + domain.id + suffix,
                  method,
                  body: { ...body, version: domain.version },
                });
              }}
            />
          ))}
      </ul>
      {query.data?.pages[0].count === 0 && (
        <p className="text-sm text-muted-foreground">No custom domains registered.</p>
      )}
      {query.hasNextPage && (
        <Button
          variant="outline"
          disabled={query.isFetchingNextPage}
          onClick={() => void query.fetchNextPage()}
        >
          Load more domains
        </Button>
      )}
    </section>
  );
}
function DomainRow({
  domain,
  pending,
  act,
  expanded,
  onExpand,
  setup,
  onRoutingChecked,
}: {
  domain: Domain;
  onRoutingChecked: () => Promise<unknown>;
  setup?: { configured: boolean; cnameTarget: string | null };
  pending: boolean;
  expanded: boolean;
  onExpand: (open: boolean) => void;
  act: (
    suffix: string,
    method: 'POST' | 'PATCH' | 'DELETE',
    body?: Record<string, unknown>,
  ) => void;
}) {
  const [showQrStyle, setShowQrStyle] = useState(false);
  const [root, setRoot] = useState(domain.rootUrl ?? ''),
    [missing, setMissing] = useState(domain.notFoundUrl ?? ''),
    [expired, setExpired] = useState(domain.expiredUrl ?? '');
  const [disabled, setDisabled] = useState(domain.disabled),
    [confirm, setConfirm] = useState<'rotate' | 'delete' | null>(null),
    [copyStatus, setCopyStatus] = useState('');
  return (
    <li className="min-w-0 border-t pt-4">
      <details
        open={expanded}
        onToggle={(event) => onExpand(event.currentTarget.open)}
        className="min-w-0 space-y-4"
      >
        <summary className="cursor-pointer break-all font-medium">
          {domain.hostname} ·{' '}
          {domain.disabled
            ? 'Disabled'
            : domain.ownershipVerified
              ? 'Ownership verified'
              : domain.ownershipState === 'lost'
                ? 'Ownership lost'
                : domain.ownershipState === 'verified'
                  ? 'Proof expired'
                  : 'Awaiting DNS proof'}
        </summary>
        {domain.verifiedUntil && (
          <p className="text-sm">
            Ownership proof valid until {new Date(domain.verifiedUntil).toLocaleString()}.
          </p>
        )}
        {domain.lastCheck === 'unavailable' && (
          <p className="text-sm">
            DNS could not be checked. Existing proof keeps its original expiry; try again later.
          </p>
        )}
        <p className="text-sm">
          {domain.routingReady
            ? 'Branded routing is ready.'
            : domain.providerConnected
              ? 'Provider record present; routing readiness still requires verification.'
              : 'TLS and branded routing are not connected.'}
        </p>
        <div className="space-y-2 text-sm">
          <p>
            Add this record in your DNS provider. Leave it in place for future ownership checks.
          </p>
          <dl className="space-y-2">
            <dt>Type</dt>
            <dd>{domain.verification.type}</dd>
            <dt>Name</dt>
            <dd className="break-all">{domain.verification.name}</dd>
            <dt>Value</dt>
            <dd className="break-all">{domain.verification.value}</dd>
          </dl>
          <Button
            variant="outline"
            onClick={() =>
              void navigator.clipboard
                .writeText(
                  'Type: TXT\nName: ' +
                    domain.verification.name +
                    '\nValue: ' +
                    domain.verification.value,
                )
                .then(() => setCopyStatus('DNS instructions copied.'))
                .catch(() => setCopyStatus('Select and copy the DNS name and value above.'))
            }
          >
            Copy DNS instructions
          </Button>
          {copyStatus && <p role="status">{copyStatus}</p>}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button
            variant="outline"
            disabled={pending || domain.disabled}
            onClick={() => act('/verify', 'POST')}
          >
            Check DNS ownership
          </Button>
          <Button variant="outline" disabled={pending} onClick={() => setConfirm('rotate')}>
            Replace ownership challenge
          </Button>
        </div>
        <RedirectDomainProvider
          provider={domain.provider}
          routingReady={domain.routingReady}
          routingSeenAt={domain.routingSeenAt}
          onRoutingChecked={onRoutingChecked}
          setup={setup}
          hostname={domain.hostname}
          verified={domain.ownershipVerified}
          disabled={domain.disabled}
          connected={domain.providerConnected}
          pending={pending}
          act={act}
        />
        <form
          className="space-y-4"
          onSubmit={(event) => {
            event.preventDefault();
            act('', 'PATCH', {
              rootUrl: root.trim() || null,
              notFoundUrl: missing.trim() || null,
              expiredUrl: expired.trim() || null,
              disabled,
            });
          }}
        >
          <p className="text-sm text-muted-foreground">
            These defaults are stored for setup. They take effect after branded routing is
            connected. Use public HTTP(S) destinations outside short-link domains.
          </p>
          <fieldset disabled={pending} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor={'domain-root-' + domain.id}>Root destination</Label>
              <Input
                id={'domain-root-' + domain.id}
                type="url"
                value={root}
                maxLength={8192}
                onChange={(event) => setRoot(event.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor={'domain-missing-' + domain.id}>Not-found destination</Label>
              <Input
                id={'domain-missing-' + domain.id}
                type="url"
                value={missing}
                maxLength={8192}
                onChange={(event) => setMissing(event.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor={'domain-expired-' + domain.id}>
                Default expired-link destination
              </Label>
              <Input
                id={'domain-expired-' + domain.id}
                type="url"
                value={expired}
                maxLength={8192}
                onChange={(event) => setExpired(event.target.value)}
              />
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={disabled}
                onChange={(event) => setDisabled(event.target.checked)}
              />
              Disable this domain
            </label>
            <Button type="submit">Save domain settings</Button>
          </fieldset>
        </form>
        {confirm ? (
          <div className="space-y-2">
            <p className="text-sm">
              {confirm === 'rotate'
                ? 'Replace the TXT challenge? Existing ownership proof stops immediately. Add the new TXT value and verify again.'
                : 'Remove this domain registration and its stored defaults? A provisioned hostname must be disconnected first.'}
            </p>
            <div className="flex flex-wrap gap-2">
              <Button
                variant="destructive"
                disabled={pending}
                onClick={() =>
                  act(
                    confirm === 'rotate' ? '/rotate' : '',
                    confirm === 'rotate' ? 'POST' : 'DELETE',
                  )
                }
              >
                {confirm === 'rotate' ? 'Confirm challenge replacement' : 'Confirm domain removal'}
              </Button>
              <Button variant="outline" disabled={pending} onClick={() => setConfirm(null)}>
                Cancel domain action
              </Button>
            </div>
          </div>
        ) : (
          <Button variant="outline" disabled={pending} onClick={() => setConfirm('delete')}>
            Remove domain registration
          </Button>
        )}
        <Button variant="outline" onClick={() => setShowQrStyle(!showQrStyle)}>
          {showQrStyle ? 'Hide saved QR style' : 'Manage saved QR style'}
        </Button>
        {showQrStyle && <RedirectQrStyleSettings domainId={domain.id} />}
      </details>
    </li>
  );
}
