import { useEffect, useId, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import { loadQrLogo, readQrLogoFile } from '@/lib/redirects/qrLogos';
import type { QrStylePreference } from '@/lib/redirects/qrPreferences';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

export function RedirectQrLogoSettings({
  preference,
  path,
  queryKey,
  disabled,
  onEditing,
  onBusy,
}: {
  preference: QrStylePreference;
  path: string;
  queryKey: (string | undefined)[];
  disabled: boolean;
  onEditing: (editing: boolean) => void;
  onBusy: (busy: boolean) => void;
}) {
  const client = useQueryClient();
  const uploadId = useId();
  const [draft, setDraft] = useState<{
    version: string | null;
    mode?: 'inherit' | 'none' | 'custom';
    file?: { data: string; image: string };
    clear?: boolean;
  } | null>(null);
  const [reading, setReading] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const preview = useQuery({
    queryKey: [
      'redirect-qr-logo-preview',
      ...queryKey,
      preference.effectiveLogo?.id,
      preference.effectiveLogo?.sha256,
    ],
    enabled: !!preference.effectiveLogo,
    queryFn: ({ signal }) => loadQrLogo(preference.effectiveLogo!, signal),
    retry: false,
    gcTime: 60000,
    staleTime: 0,
  });
  const save = useMutation({
    mutationFn: (request: NonNullable<typeof draft>) =>
      request.file
        ? memberRedirectApi<QrStylePreference>(path + '/logo', 'POST', {
            version: request.version,
            image: request.file.image,
          })
        : memberRedirectApi<QrStylePreference>(path, 'PATCH', {
            version: request.version,
            ...(request.clear ? { clearLogo: true } : { logoMode: request.mode }),
          }),
    onSuccess: async (data) => {
      // This component is keyed by account and domain; late responses update only their captured scope.
      await client.cancelQueries({ queryKey, exact: true });
      client.setQueryData(queryKey, data);
      setDraft(null);
      onEditing(false);
      setNotice('Saved QR logo.');
      await client.invalidateQueries({ queryKey: ['redirect-qr-style'] });
    },
  });
  useEffect(() => {
    onBusy(reading || save.isPending);
    return () => onBusy(false);
  }, [reading, save.isPending, onBusy]);
  useEffect(() => () => onEditing(false), [onEditing]);
  const busy = disabled || reading || save.isPending;
  const discard = () => {
    setDraft(null);
    setError('');
    setNotice('');
    save.reset();
    onEditing(false);
  };
  const selectFile = async (file?: File) => {
    if (!file) return;
    const version = preference.version;
    setReading(true);
    onEditing(true);
    setError('');
    setNotice('');
    save.reset();
    try {
      setDraft({ version, file: await readQrLogoFile(file) });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not read logo');
      onEditing(!!draft);
    } finally {
      setReading(false);
    }
  };
  return (
    <div className="space-y-4 border-t pt-4" aria-label="Saved QR logo settings">
      <h5 className="font-semibold">Saved logo</h5>
      <p className="text-sm">
        {preference.domainId
          ? 'Inherit the workspace logo, hide it, or use a domain logo.'
          : 'Set the default logo for future QR exports.'}{' '}
        Uploaded logos are publicly hosted. Use artwork you are comfortable sharing.
      </p>
      <label className="block space-y-1 text-sm">
        Logo choice
        <select
          aria-label="Saved QR logo choice"
          className="h-10 w-full rounded-element border bg-background px-4"
          disabled={busy || !!draft?.file || !!draft?.clear}
          value={draft?.mode ?? preference.logoMode ?? 'inherit'}
          onChange={(event) => {
            setDraft({
              version: draft ? draft.version : preference.version,
              mode: event.target.value as 'inherit' | 'none' | 'custom',
            });
            onEditing(true);
            setNotice('');
            save.reset();
          }}
        >
          <option value="inherit">
            {preference.domainId ? 'Inherit workspace logo' : 'No workspace logo'}
          </option>
          <option value="none">Hide logo</option>
          <option value="custom" disabled={!preference.logoAsset}>
            Use saved custom logo
          </option>
        </select>
      </label>
      {preference.logoAsset && preference.logoMode !== 'custom' && (
        <p className="text-xs text-muted-foreground">
          Your custom logo is retained and can be used again.
        </p>
      )}
      <label htmlFor={uploadId} className="block space-y-1 text-sm">
        Upload a new saved logo
        <Input
          id={uploadId}
          aria-label="Upload saved QR logo"
          type="file"
          accept="image/png,image/jpeg"
          disabled={busy || !!draft}
          onChange={(event) => {
            const file = event.target.files?.[0];
            event.target.value = '';
            void selectFile(file);
          }}
        />
      </label>
      <p className="text-xs text-muted-foreground">
        PNG or JPG, up to 1.5 MB and 1024 × 1024 pixels.
      </p>
      {(draft?.file?.data || preview.data) && !draft?.clear && (
        <img
          src={draft?.file?.data ?? preview.data}
          alt="QR logo preview"
          width={64}
          height={64}
          className="size-16 object-contain"
        />
      )}
      {preview.isError && !draft?.file && (
        <div className="space-y-2">
          <p role="alert">Saved logo preview could not be loaded.</p>
          <Button size="sm" variant="outline" onClick={() => void preview.refetch()}>
            Retry logo preview
          </Button>
        </div>
      )}
      {reading && <p role="status">Preparing saved logo…</p>}
      {(error || save.isError) && <p role="alert">{error || save.error?.message}</p>}
      {notice && <p role="status">{notice}</p>}
      {draft?.clear && (
        <p className="text-sm">
          Clear this saved custom logo? Future exports will{' '}
          {preference.domainId ? 'inherit the workspace logo' : 'have no workspace logo'}.
          Downloaded codes keep their image.
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button disabled={busy || !draft} onClick={() => draft && save.mutate(draft)}>
          {draft?.clear ? 'Confirm clear logo' : 'Save QR logo'}
        </Button>
        {draft && (
          <Button variant="ghost" disabled={reading || save.isPending} onClick={discard}>
            Discard logo change
          </Button>
        )}
        {!draft && preference.logoAsset && (
          <Button
            variant="outline"
            disabled={busy}
            onClick={() => {
              setDraft({ version: preference.version, clear: true });
              onEditing(true);
              setNotice('');
              save.reset();
            }}
          >
            Clear saved logo
          </Button>
        )}
      </div>
    </div>
  );
}
