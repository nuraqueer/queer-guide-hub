import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import { useRedirectDomainChoices } from '@/hooks/useRedirectDomainChoices';
import { RedirectDomainSelect } from './RedirectDomainSelect';
import { Button } from '@/components/ui/button';
interface Preference {
  domainId: string | null;
  hostname: string | null;
  version: string;
  ready: boolean;
}
export function RedirectPrimaryDomain({ userId }: { userId: string }) {
  const client = useQueryClient();
  const key = ['redirect-domain-preference', userId];
  const preference = useQuery({
    queryKey: key,
    queryFn: () => memberRedirectApi<Preference>('/domain-preference'),
    retry: false,
    staleTime: 0,
  });
  const domain = useRedirectDomainChoices(
    userId,
    preference.data
      ? { id: preference.data.domainId, hostname: preference.data.hostname }
      : undefined,
  );
  const [draft, setDraft] = useState<{ version: string; value: string } | null>(null);
  const [saved, setSaved] = useState(false);
  const change = useMutation({
    mutationFn: () =>
      memberRedirectApi<Preference>('/domain-preference', 'PATCH', {
        version: draft?.version,
        domainId: draft?.value || null,
      }),
    onSuccess: async (updated) => {
      client.setQueryData(key, updated);
      setDraft(null);
      domain.resetSelection();
      setSaved(true);
      await Promise.all([
        client.invalidateQueries({ queryKey: key }),
        client.invalidateQueries({ queryKey: ['redirect-domain-choices'] }),
      ]);
    },
  });
  const selectable =
    !domain.selected || !!domain.query.data?.data.some((item) => item.id === domain.selected);
  return (
    <section aria-label="Primary domain" className="space-y-4 border-t pt-4">
      <h4 className="font-semibold">Primary domain</h4>
      <p className="text-sm">The initial domain for new links. Existing URLs keep their domain.</p>
      {preference.isPending && <p role="status">Loading primary domain…</p>}
      {preference.isError && (
        <div>
          <p role="alert">Could not load the primary domain.</p>
          <Button type="button" variant="outline" onClick={() => void preference.refetch()}>
            Retry primary domain
          </Button>
        </div>
      )}
      {preference.data && (
        <form
          className="space-y-4"
          onSubmit={(event) => {
            event.preventDefault();
            if (draft && selectable && domain.valid) change.mutate();
          }}
        >
          <RedirectDomainSelect
            selection={{
              ...domain,
              setSelected: (value) => {
                domain.setSelected(value);
                setDraft((current) => ({
                  version: current?.version ?? preference.data.version,
                  value,
                }));
                setSaved(false);
              },
            }}
            disabled={change.isPending}
          />
          {!preference.data.ready && (
            <p role="status" className="text-sm">
              The saved primary domain is unavailable. New links require an explicit available
              domain choice.
            </p>
          )}
          <Button
            type="submit"
            disabled={!draft || !selectable || !domain.valid || change.isPending}
          >
            {change.isPending ? 'Saving…' : 'Save primary domain'}
          </Button>
        </form>
      )}
      <Button
        type="button"
        variant="ghost"
        disabled={change.isPending}
        onClick={() => {
          setDraft(null);
          domain.resetSelection();
          change.reset();
          setSaved(false);
          void Promise.all([preference.refetch(), domain.query.refetch()]);
        }}
      >
        Reload primary domain
      </Button>
      {change.isError && (
        <p role="alert" className="text-destructive">
          {change.error.message}
        </p>
      )}
      {saved && <p role="status">Primary domain saved.</p>}
    </section>
  );
}
