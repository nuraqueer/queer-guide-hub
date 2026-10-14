import { RedirectPresentationFields } from './RedirectPresentationFields';
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { untypedFrom, untypedRpc } from '@/integrations/supabase/untyped';
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
import {
  policyErrors,
  type LinkPolicy,
  type VariantPerformance,
} from '../../../../supabase/functions/_shared/link-policy';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { parseLinkExpiration } from '@/lib/redirects/expiration';

function localDate(value?: string) {
  if (!value) return '';
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}
const isoDate = (value: string) => (value ? new Date(value).toISOString() : undefined);

function PolicyForm({
  row,
  initial,
  hasPassword,
  stats,
  onClose,
}: {
  row: InventoryRedirect;
  initial: LinkPolicy;
  hasPassword: boolean;
  stats: VariantPerformance[];
  onClose: () => void;
}) {
  const [policy, setPolicy] = useState<LinkPolicy>(initial);
  const [passwordEnabled, setPasswordEnabled] = useState(hasPassword);
  const [password, setPassword] = useState('');
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const [expirationPhrase, setExpirationPhrase] = useState('');
  const client = useQueryClient();
  const save = async () => {
    if (uploading) return;
    const errors = policyErrors(policy);
    if (policy.cloaked && row.target?.toLowerCase().startsWith('http:'))
      errors.push('Change the link destination to HTTPS before enabling framing');
    if (passwordEnabled && !hasPassword && !password)
      errors.push('Enter or generate a link password');
    if (errors.length) {
      setError(errors.join('; '));
      return;
    }
    setError('');
    setSaving(true);
    try {
      const { data, error: saveError } = await supabase.functions.invoke('save-redirect-policy', {
        body: {
          redirect_id: row.manualId,
          policy,
          ...(passwordEnabled ? (password ? { password } : {}) : { remove_password: true }),
        },
      });
      if (saveError || data?.error) throw new Error(data?.error ?? saveError?.message);
      await Promise.allSettled([
        client.invalidateQueries({ queryKey: ['redirect-link-policy', row.manualId] }),
        client.invalidateQueries({ queryKey: ['cms-content-list'] }),
      ]);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save policy');
    } finally {
      setSaving(false);
    }
  };
  return (
    <form
      className="space-y-6"
      onSubmit={(event) => {
        event.preventDefault();
        void save();
      }}
    >
      <RedirectPresentationFields
        id={row.manualId!}
        policy={policy}
        onChange={setPolicy}
        onUploading={setUploading}
      />
      <fieldset className="space-y-2">
        <legend className="font-medium">Conversion tracking</legend>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={policy.track_conversions === true}
            onChange={(event) => setPolicy({ ...policy, track_conversions: event.target.checked })}
          />
          Attribute leads and sales
        </label>
        <p className="text-sm text-muted-foreground">
          Include a click ID in the destination URL for your connected signup or checkout. Visit
          counts work independently.
        </p>
      </fieldset>
      <fieldset className="space-y-2">
        <legend className="font-medium">Device destinations</legend>
        {(['ios', 'android'] as const).map((device) => (
          <div key={device} className="space-y-2">
            <Label htmlFor={'target-' + device}>{device === 'ios' ? 'iOS' : 'Android'}</Label>
            <Input
              id={'target-' + device}
              placeholder="Optional destination URL"
              value={policy.device_targets?.[device] ?? ''}
              onChange={(event) => {
                const targets = { ...policy.device_targets };
                if (event.target.value) targets[device] = event.target.value;
                else delete targets[device];
                setPolicy({ ...policy, device_targets: targets });
              }}
            />
          </div>
        ))}
      </fieldset>
      <fieldset className="space-y-2">
        <legend className="font-medium">Country destinations</legend>
        {Object.entries(policy.geo_targets ?? {}).map(([country, target]) => (
          <div className="flex gap-2" key={country}>
            <span className="self-center text-sm">{country}</span>
            <Input
              aria-label={'Destination for ' + country}
              value={target}
              onChange={(event) =>
                setPolicy({
                  ...policy,
                  geo_targets: { ...policy.geo_targets, [country]: event.target.value },
                })
              }
            />
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => {
                const targets = { ...policy.geo_targets };
                delete targets[country];
                setPolicy({ ...policy, geo_targets: targets });
              }}
            >
              Remove
            </Button>
          </div>
        ))}
        <CountryRule
          onAdd={(country) =>
            setPolicy({
              ...policy,
              geo_targets: { ...policy.geo_targets, [country]: row.target ?? '' },
            })
          }
        />
      </fieldset>
      <fieldset className="space-y-2">
        <legend className="font-medium">A/B experiment</legend>
        <p className="text-xs text-muted-foreground">
          Device and country rules take priority. Remaining visits follow these percentages.
        </p>
        {!policy.experiment ? (
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() =>
              setPolicy({
                ...policy,
                experiment: {
                  starts_at: new Date().toISOString(),
                  ends_at: new Date(Date.now() + 14 * 86400000).toISOString(),
                  variants: [
                    { id: crypto.randomUUID(), url: row.target ?? '', weight: 50 },
                    { id: crypto.randomUUID(), url: '', weight: 50 },
                  ],
                },
              })
            }
          >
            Add A/B experiment
          </Button>
        ) : (
          <>
            {policy.experiment.variants.map((variant) => (
              <div key={variant.id} className="space-y-2 rounded-element bg-muted p-4">
                <div className="flex flex-wrap gap-2">
                  <Input
                    className="min-w-0 flex-1"
                    aria-label="Variant destination"
                    value={variant.url}
                    onChange={(event) =>
                      setPolicy({
                        ...policy,
                        experiment: {
                          ...policy.experiment!,
                          variants: policy.experiment!.variants.map((item) =>
                            item.id === variant.id ? { ...item, url: event.target.value } : item,
                          ),
                        },
                      })
                    }
                  />
                  <Input
                    className="w-24"
                    aria-label="Traffic percentage"
                    type="number"
                    min={10}
                    max={90}
                    value={variant.weight}
                    onChange={(event) =>
                      setPolicy({
                        ...policy,
                        experiment: {
                          ...policy.experiment!,
                          variants: policy.experiment!.variants.map((item) =>
                            item.id === variant.id
                              ? { ...item, weight: Number(event.target.value) }
                              : item,
                          ),
                        },
                      })
                    }
                  />
                </div>
                <p className="text-xs tabular-nums">
                  {stats.find((item) => item.id === variant.id)?.clicks ?? 0} visits ·{' '}
                  {stats.find((item) => item.id === variant.id)?.leads ?? 0} leads ·{' '}
                  {stats.find((item) => item.id === variant.id)?.sales ?? 0} sales
                </p>
                <div className="flex gap-2">
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    disabled={policy.experiment!.variants.length <= 2}
                    onClick={() =>
                      setPolicy({
                        ...policy,
                        experiment: {
                          ...policy.experiment!,
                          variants: policy.experiment!.variants.filter(
                            (item) => item.id !== variant.id,
                          ),
                        },
                      })
                    }
                  >
                    Remove variant
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      setPolicy({
                        ...policy,
                        experiment: { ...policy.experiment!, completed_target: variant.url },
                      })
                    }
                  >
                    End test with this winner
                  </Button>
                </div>
              </div>
            ))}
            {policy.experiment.completed_target && (
              <p className="text-sm">Selected winner: {policy.experiment.completed_target}</p>
            )}
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={policy.experiment.variants.length >= 5}
              onClick={() =>
                setPolicy({
                  ...policy,
                  experiment: {
                    ...policy.experiment!,
                    variants: [
                      ...policy.experiment!.variants,
                      { id: crypto.randomUUID(), url: '', weight: 10 },
                    ],
                  },
                })
              }
            >
              Add destination
            </Button>
            <div className="space-y-2">
              <Label htmlFor="experiment-end">Experiment ends</Label>
              <Input
                id="experiment-end"
                type="datetime-local"
                value={localDate(policy.experiment.ends_at)}
                onChange={(event) =>
                  setPolicy({
                    ...policy,
                    experiment: {
                      ...policy.experiment!,
                      ends_at: isoDate(event.target.value) ?? '',
                    },
                  })
                }
              />
            </div>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => {
                const next = { ...policy };
                delete next.experiment;
                setPolicy(next);
              }}
            >
              Remove experiment
            </Button>
          </>
        )}
      </fieldset>
      <fieldset className="space-y-2">
        <legend className="font-medium">Expiration</legend>
        <div className="flex flex-wrap gap-2">
          <Input
            className="min-w-0 flex-1"
            aria-label="Expiration phrase"
            placeholder="In 2 hours, tomorrow at 5PM…"
            value={expirationPhrase}
            onChange={(event) => setExpirationPhrase(event.target.value)}
          />
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={!expirationPhrase.trim()}
            onClick={() => {
              try {
                setPolicy({ ...policy, expires_at: parseLinkExpiration(expirationPhrase) });
                setError('');
              } catch (err) {
                setError(err instanceof Error ? err.message : 'Invalid expiration');
              }
            }}
          >
            Apply expiration
          </Button>
        </div>
        <Label htmlFor="policy-expiry">Expires at</Label>
        <Input
          id="policy-expiry"
          type="datetime-local"
          value={localDate(policy.expires_at)}
          onChange={(event) => setPolicy({ ...policy, expires_at: isoDate(event.target.value) })}
        />
        <Label htmlFor="policy-expired-target">Expired destination</Label>
        <Input
          id="policy-expired-target"
          placeholder="Optional fallback URL"
          value={policy.expired_target ?? ''}
          onChange={(event) =>
            setPolicy({ ...policy, expired_target: event.target.value || undefined })
          }
        />
      </fieldset>
      <fieldset className="space-y-2">
        <legend className="font-medium">Password protection</legend>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={passwordEnabled}
            onChange={(event) => setPasswordEnabled(event.target.checked)}
          />
          Require a password
        </label>
        {passwordEnabled && (
          <>
            <Input
              aria-label={hasPassword ? 'Replacement password' : 'Link password'}
              type="password"
              autoComplete="new-password"
              value={password}
              maxLength={256}
              placeholder={
                hasPassword ? 'Leave empty to keep the current password' : 'Enter a password'
              }
              onChange={(event) => setPassword(event.target.value)}
            />
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() =>
                setPassword(
                  Array.from(crypto.getRandomValues(new Uint8Array(16)), (value) =>
                    value.toString(16).padStart(2, '0'),
                  ).join(''),
                )
              }
            >
              Generate password
            </Button>
            {password && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => void navigator.clipboard.writeText(password)}
              >
                Copy new password
              </Button>
            )}
          </>
        )}
      </fieldset>
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      <Button type="submit" disabled={saving || uploading}>
        {saving ? 'Saving…' : 'Save link behavior'}
      </Button>
    </form>
  );
}
function CountryRule({ onAdd }: { onAdd: (country: string) => void }) {
  const [country, setCountry] = useState('');
  return (
    <div className="flex gap-2">
      <Input
        aria-label="Country code"
        placeholder="Country code, e.g. CH"
        maxLength={2}
        value={country}
        onChange={(event) => setCountry(event.target.value.toUpperCase())}
      />
      <Button
        type="button"
        variant="outline"
        size="sm"
        disabled={!/^[A-Z]{2}$/.test(country)}
        onClick={() => {
          onAdd(country);
          setCountry('');
        }}
      >
        Add country
      </Button>
    </div>
  );
}
export function RedirectPolicyDialog({
  row,
  onClose,
}: {
  row: InventoryRedirect;
  onClose: () => void;
}) {
  const query = useQuery({
    queryKey: ['redirect-link-policy', row.manualId],
    queryFn: async () => {
      const results = await Promise.allSettled([
        untypedFrom('redirect_link_policies')
          .select('policy,has_password')
          .eq('redirect_id', row.manualId!)
          .maybeSingle(),
        untypedFrom('redirects').select('end_at').eq('id', row.manualId!).single(),
        untypedRpc<VariantPerformance[]>('redirect_variant_performance', {
          p_redirect_id: row.manualId,
        }),
      ]);
      const failed = results.find((result) => result.status === 'rejected');
      if (failed?.status === 'rejected') throw failed.reason;
      const [setting, link, performance] = results.map((result) =>
        result.status === 'fulfilled' ? result.value : null,
      );
      if (setting?.error || link?.error || performance?.error)
        throw new Error(
          setting?.error?.message ?? link?.error?.message ?? performance?.error?.message,
        );
      const data = setting?.data as { policy?: LinkPolicy; has_password?: boolean } | null;
      const record = link?.data as { end_at: string | null };
      return {
        policy: {
          ...(data?.policy ?? {}),
          ...(record.end_at ? { expires_at: record.end_at } : {}),
        },
        hasPassword: data?.has_password ?? false,
        stats: (performance?.data as VariantPerformance[]) ?? [],
      };
    },
  });
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-3xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Link behavior</DialogTitle>
          <DialogDescription>
            {row.source} · Targeting, experiments, expiration, and password access.
          </DialogDescription>
        </DialogHeader>
        {query.isPending && <p role="status">Loading link settings…</p>}
        {query.isError && (
          <p role="alert" className="text-destructive">
            Could not load link settings. {query.error.message}
          </p>
        )}
        {query.data && (
          <PolicyForm
            row={row}
            initial={query.data.policy}
            hasPassword={query.data.hasPassword}
            stats={query.data.stats}
            onClose={onClose}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}
