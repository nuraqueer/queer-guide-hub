import { AdminEmpty } from '@/components/admin/primitives/AdminEmpty';
import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { useRedirectCredentials } from '@/hooks/useRedirectCredentials';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { formatDateTime } from '@/lib/format';

export function RedirectConversionSetup({
  links,
  onClose,
}: {
  links: InventoryRedirect[];
  onClose: () => void;
}) {
  const credentials = useRedirectCredentials();
  const [name, setName] = useState(''),
    [days, setDays] = useState('30'),
    [limited, setLimited] = useState(false);
  const [ids, setIds] = useState<string[]>([]),
    [search, setSearch] = useState(''),
    [secret, setSecret] = useState('');
  const [openedAt] = useState(() => Date.now());
  const [confirm, setConfirm] = useState<string | null>(null);
  const managed = links.filter(
    (link) =>
      link.manualId &&
      link.source.startsWith('/go/') &&
      (link.source + ' ' + link.target).toLowerCase().includes(search.toLowerCase()),
  );
  const create = async () => {
    const result = await credentials.create.mutateAsync({
      name,
      expiresAt: new Date(Date.now() + Number(days) * 86400000).toISOString(),
      ...(limited ? { redirectIds: ids } : {}),
    });
    setSecret(result.secret);
    setName('');
    credentials.create.reset();
  };
  const copy = (value: string) =>
    void navigator.clipboard
      .writeText(value)
      .then(() => toast.success('Copied'))
      .catch(() => toast.error('Could not copy'));
  const sample = `POST https://queer.guide/api/redirects/track/lead\nAuthorization: Bearer YOUR_SERVER_CREDENTIAL\nContent-Type: application/json\n\n${JSON.stringify({ clickId: 'CLICK_ID_FROM_DESTINATION', customerExternalId: 'CUSTOMER_ID', eventId: 'signup:CUSTOMER_ID', eventName: 'Sign up' }, null, 2)}`;
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-3xl grid-cols-1 overflow-y-auto [&>*]:min-w-0">
        <DialogHeader>
          <DialogTitle>Conversion setup</DialogTitle>
          <DialogDescription>
            Connect managed links to signups and purchases using server tracking credentials.
          </DialogDescription>
        </DialogHeader>
        <ol className="list-decimal space-y-2 pl-6 text-sm">
          <li>
            Enable “Attribute leads and sales” in the managed link’s settings. The destination
            receives a unique <code>qg_click_id</code>.
          </li>
          <li>
            Save that click ID in your destination’s attribution session. On queer.guide, confirmed
            signups are connected automatically when analytics consent permits it.
          </li>
          <li>
            Send lead or sale events from your server. Use a stable event ID for retries. Later
            sales can use the same customer ID without resending the click ID.
          </li>
        </ol>
        {secret ? (
          <section className="space-y-2" aria-label="New server credential">
            <p className="font-medium">Copy your credential now</p>
            <p className="text-sm text-muted-foreground">
              It is shown once. Keep it on your server; use the click ID in browser code.
            </p>
            <Input aria-label="New server credential" type="password" readOnly value={secret} />
            <div className="flex gap-2">
              <Button onClick={() => copy(secret)}>Copy credential</Button>
              <Button variant="outline" onClick={() => setSecret('')}>
                Done
              </Button>
            </div>
          </section>
        ) : (
          <form
            className="space-y-4"
            onSubmit={(event) => {
              event.preventDefault();
              void create().catch(() => {});
            }}
          >
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="redirect-credential-name">Credential name</Label>
                <Input
                  id="redirect-credential-name"
                  maxLength={100}
                  required
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="redirect-credential-expiry">Expires after</Label>
                <select
                  id="redirect-credential-expiry"
                  className="h-10 w-full rounded-element border bg-background px-4"
                  value={days}
                  onChange={(event) => setDays(event.target.value)}
                >
                  <option value="7">7 days</option>
                  <option value="30">30 days</option>
                  <option value="90">90 days</option>
                  <option value="365">1 year</option>
                </select>
              </div>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={limited}
                onChange={(event) => setLimited(event.target.checked)}
              />
              Limit to selected managed links
            </label>
            {limited && (
              <div className="space-y-2">
                <Input
                  aria-label="Search credential link scope"
                  placeholder="Search managed links"
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                />
                <div className="max-h-48 space-y-2 overflow-y-auto">
                  {managed.slice(0, 100).map((link) => (
                    <label className="flex items-center gap-2 text-sm" key={link.manualId}>
                      <input
                        type="checkbox"
                        checked={ids.includes(link.manualId!)}
                        disabled={ids.length >= 100 && !ids.includes(link.manualId!)}
                        onChange={(event) =>
                          setIds(
                            event.target.checked
                              ? [...ids, link.manualId!]
                              : ids.filter((id) => id !== link.manualId),
                          )
                        }
                      />
                      <span className="break-all">{link.source}</span>
                    </label>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">
                  {ids.length} selected
                  {managed.length > 100 ? ' · Search to narrow the first 100 matches' : ''}
                </p>
                {!managed.length && <p className="text-sm">No matching managed links.</p>}
              </div>
            )}
            <p className="text-sm text-muted-foreground">
              Permission: write conversion events
              {limited ? ' for selected links' : ' for all managed links'}. This credential cannot
              manage links or credentials.
            </p>
            {credentials.create.isError && (
              <p role="alert" className="text-destructive">
                {credentials.create.error.message}
              </p>
            )}
            <Button
              type="submit"
              disabled={credentials.create.isPending || !name.trim() || (limited && !ids.length)}
            >
              {credentials.create.isPending ? 'Creating…' : 'Create server credential'}
            </Button>
          </form>
        )}
        <section className="space-y-2">
          <h3 className="font-medium">Server request</h3>
          <pre className="overflow-x-auto rounded-element bg-muted p-4 text-xs">{sample}</pre>
          <Button variant="outline" size="sm" onClick={() => copy(sample)}>
            Copy request example
          </Button>
          <p className="text-sm text-muted-foreground">
            Use <code>/track/sale</code> for purchases, with <code>amount</code> in major currency
            units (49.90 means CHF 49.90) and an uppercase three-letter <code>currency</code>. Never
            combine currencies in a revenue total.
          </p>
        </section>
        <section className="space-y-2">
          <h3 className="font-medium">Credentials</h3>
          {credentials.isPending && <p role="status">Loading credentials…</p>}
          {credentials.isError && (
            <div role="alert">
              <p>{credentials.error.message}</p>
              <Button variant="outline" onClick={() => void credentials.refetch()}>
                Retry credentials
              </Button>
            </div>
          )}
          {credentials.revoke.isError && (
            <p role="alert" className="text-destructive">
              {credentials.revoke.error.message}
            </p>
          )}
          <ul className="space-y-2">
            {credentials.data?.map((item) => (
              <li
                className="flex flex-wrap items-center justify-between gap-2 border-t py-2"
                key={item.id}
              >
                <div>
                  <p className="font-medium">
                    {item.name} · <code className="text-xs">{item.prefix}…</code>
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {item.revoked_at
                      ? 'Revoked'
                      : Date.parse(item.expires_at) <= openedAt
                        ? 'Expired'
                        : 'Active'}{' '}
                    ·{' '}
                    {item.redirect_ids
                      ? item.redirect_ids.length + ' selected links'
                      : 'All managed links'}{' '}
                    · Expires {formatDateTime(item.expires_at)} · Last used{' '}
                    {item.last_used_at ? formatDateTime(item.last_used_at) : 'Never'}
                  </p>
                </div>
                {!item.revoked_at &&
                  (confirm === item.id ? (
                    <div className="flex gap-2">
                      <Button
                        size="sm"
                        variant="destructive"
                        disabled={credentials.revoke.isPending}
                        onClick={() =>
                          void credentials.revoke
                            .mutateAsync(item.id)
                            .then(() => setConfirm(null))
                            .catch(() => {})
                        }
                      >
                        Confirm revoke
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => setConfirm(null)}>
                        Cancel
                      </Button>
                    </div>
                  ) : (
                    <Button variant="outline" size="sm" onClick={() => setConfirm(item.id)}>
                      Revoke
                    </Button>
                  ))}
              </li>
            ))}
          </ul>
          {credentials.data?.length === 0 && <AdminEmpty noun="server credentials" />}
        </section>
      </DialogContent>
    </Dialog>
  );
}
