import { useCallback, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '@/hooks/useAuth';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import { qrStylePreferencePath, type QrStylePreference } from '@/lib/redirects/qrPreferences';
import { qrStyleError, type QrStyle } from '@/lib/redirects/qr';
import { RedirectQrLogoSettings } from './RedirectQrLogoSettings';
import { QrStyleFields } from './QrStyleFields';
import { Button } from '@/components/ui/button';
export function RedirectQrStyleSettings({ domainId }: { domainId?: string }) {
  const { user } = useAuth();
  const client = useQueryClient();
  const path = qrStylePreferencePath(domainId);
  const queryKey = ['redirect-qr-preference', user?.id, domainId ?? 'workspace'];
  const query = useQuery({
    queryKey,
    enabled: !!user,
    queryFn: ({ signal }) => memberRedirectApi<QrStylePreference>(path, 'GET', undefined, signal),
    retry: false,
    staleTime: 0,
  });
  const scope = (user?.id ?? '') + ':' + (domainId ?? 'workspace');
  const [rawDraft, setDraft] = useState<{
    scope: string;
    version: string | null;
    style: QrStyle;
  } | null>(null);
  const draft = rawDraft?.scope === scope ? rawDraft : null;
  const [logoEditingScope, setLogoEditingScope] = useState<string | null>(null);
  const onLogoEditing = useCallback(
    (editing: boolean) =>
      setLogoEditingScope((previous) => (editing ? scope : previous === scope ? null : previous)),
    [scope],
  );
  const [logoBusyScope, setLogoBusyScope] = useState<string | null>(null);
  const onLogoBusy = useCallback(
    (busy: boolean) =>
      setLogoBusyScope((previous) => (busy ? scope : previous === scope ? null : previous)),
    [scope],
  );
  const [reloadEpoch, setReloadEpoch] = useState(0);
  const logoEditing = logoEditingScope === scope;
  const [notice, setNotice] = useState<{ scope: string; text: string } | null>(null);
  const save = useMutation({
    mutationFn: (request: {
      scope: string;
      queryKey: typeof queryKey;
      path: string;
      version: string | null;
      style: QrStyle | null;
    }) =>
      memberRedirectApi<QrStylePreference>(request.path, 'PATCH', {
        version: request.version,
        style: request.style,
      }),
    onSuccess: async (data, request) => {
      await client.cancelQueries({ queryKey: request.queryKey, exact: true });
      client.setQueryData(request.queryKey, data);
      setDraft((previous) => (previous?.scope === request.scope ? null : previous));
      setNotice({ scope: request.scope, text: 'Saved QR style.' });
      await client.invalidateQueries({ queryKey: ['redirect-qr-style'] });
    },
  });
  if (query.isPending) return <p role="status">Loading saved QR style…</p>;
  if (query.isError || !query.data)
    return (
      <div>
        <p role="alert">Could not load saved QR style.</p>
        <Button variant="outline" onClick={() => void query.refetch()}>
          Retry QR settings
        </Button>
      </div>
    );
  const style = draft?.style ?? query.data.effectiveStyle;
  const submit = (reset: boolean) =>
    save.mutate({
      scope,
      queryKey,
      path,
      version: draft ? draft.version : query.data!.version,
      style: reset ? null : style,
    });
  const error = qrStyleError(style);
  return (
    <section
      className="space-y-4 border-t pt-4"
      aria-label={domainId ? 'Domain QR style' : 'Workspace QR style'}
    >
      <h4 className="font-semibold">{domainId ? 'Domain' : 'Workspace'} QR style</h4>
      <p className="text-sm">
        {domainId
          ? 'Saving stores this whole appearance for the domain. Reset to inherit the workspace style.'
          : 'Saved defaults apply to managed links and owner inventory exports. Domain overrides take precedence.'}{' '}
        Changes affect future exports.
      </p>
      <QrStyleFields
        style={style}
        setStyle={(value) => {
          setDraft({
            scope,
            version: draft ? draft.version : query.data!.version,
            style: typeof value === 'function' ? value(style) : value,
          });
          setNotice(null);
        }}
        disabled={save.isPending || logoEditing}
        allowLogo={false}
      />
      {(error || save.isError) && <p role="alert">{error || save.error?.message}</p>}
      {notice?.scope === scope && <p role="status">{notice.text}</p>}
      <div className="flex flex-wrap gap-2">
        <Button
          disabled={!draft || !!error || save.isPending || logoEditing}
          onClick={() => submit(false)}
        >
          Save QR style
        </Button>
        <Button
          variant="outline"
          disabled={save.isPending || logoEditing || !Object.keys(query.data.style).length}
          onClick={() => submit(true)}
        >
          Reset QR overrides
        </Button>
        <Button
          variant="ghost"
          disabled={save.isPending || logoBusyScope === scope}
          onClick={async () => {
            const next = await query.refetch();
            if (!next.isError) {
              setDraft(null);
              setReloadEpoch((epoch) => epoch + 1);
              setLogoEditingScope(null);
              save.reset();
              setNotice({ scope, text: 'QR settings reloaded.' });
            }
          }}
        >
          Reload QR settings
        </Button>
      </div>
      <RedirectQrLogoSettings
        key={scope + ':' + reloadEpoch}
        preference={query.data}
        path={path}
        queryKey={queryKey}
        disabled={!!draft || save.isPending || query.isFetching}
        onBusy={onLogoBusy}
        onEditing={onLogoEditing}
      />
    </section>
  );
}
