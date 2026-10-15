import { useEffect, useId, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '@/hooks/useAuth';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import { loadQrLogo, readQrLogoFile } from '@/lib/redirects/qrLogos';
import type { PasswordBranding } from '@/lib/redirects/passwordBranding';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
export function RedirectPasswordBranding({
  linkId,
  readOnly = false,
}: {
  linkId: string;
  readOnly?: boolean;
}) {
  const { user } = useAuth();
  return user ? (
    <BrandingEditor
      key={user.id + ':' + linkId}
      account={user.id}
      linkId={linkId}
      readOnly={readOnly}
    />
  ) : null;
}
function BrandingEditor({
  account,
  linkId,
  readOnly,
}: {
  account: string;
  linkId: string;
  readOnly: boolean;
}) {
  const client = useQueryClient(),
    fieldId = useId(),
    alive = useRef(true),
    controller = useRef<AbortController | null>(null),
    readNonce = useRef(0);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      controller.current?.abort();
    };
  }, []);
  const path = '/links/' + linkId + '/password-branding',
    queryKey = ['redirect-password-branding', account, linkId];
  const query = useQuery({
    queryKey,
    queryFn: ({ signal }) => memberRedirectApi<PasswordBranding>(path, 'GET', undefined, signal),
    retry: false,
    gcTime: 0,
    staleTime: 0,
  });
  const [draft, setDraft] = useState<{
      version: string | null;
      name: string;
      file?: { data: string; image: string };
      clear?: boolean;
    } | null>(null),
    [busy, setBusy] = useState(false),
    [reading, setReading] = useState(false),
    [notice, setNotice] = useState(''),
    [blocked, setBlocked] = useState(false);
  const profile = query.data;
  const preview = useQuery({
    queryKey: [
      'redirect-password-logo',
      account,
      linkId,
      profile?.logoAsset?.id,
      profile?.logoAsset?.sha256,
    ],
    enabled: !query.isError && !!profile?.logoAsset,
    queryFn: ({ signal }) => loadQrLogo(profile!.logoAsset!, signal),
    retry: false,
    gcTime: 0,
  });
  const editable = !!profile?.canEdit && !readOnly && !query.isError;
  const changed = !!draft && draft.version !== profile?.version;
  const reload = async () => {
    if (busy || reading) return;
    controller.current?.abort();
    setDraft(null);
    setBlocked(false);
    setNotice('');
    await query.refetch();
  };
  const select = async (file?: File) => {
    if (!file || !editable || busy) return;
    const nonce = ++readNonce.current;
    const base = draft ?? { version: profile!.version, name: profile!.brandName ?? '' };
    setReading(true);
    setNotice('');
    try {
      const result = await readQrLogoFile(file);
      if (alive.current && readNonce.current === nonce)
        setDraft({ ...base, file: result, clear: false });
    } catch (error) {
      if (alive.current && readNonce.current === nonce) setNotice((error as Error).message);
    } finally {
      if (alive.current && readNonce.current === nonce) setReading(false);
    }
  };
  const save = async (upload = false) => {
    if (!editable || !draft || busy || reading || changed || blocked) return;
    const snapshot = draft,
      abort = new AbortController();
    controller.current = abort;
    setBusy(true);
    setNotice(upload ? 'Uploading password-page logo…' : 'Saving public branding…');
    try {
      const result = await memberRedirectApi<PasswordBranding & { retryAfter?: number }>(
        path + (upload ? '/logo' : ''),
        upload ? 'POST' : 'PATCH',
        upload
          ? { version: snapshot.version, image: snapshot.file!.image }
          : {
              version: snapshot.version,
              brandName: snapshot.name.trim() || null,
              ...(snapshot.clear ? { clearLogo: true } : {}),
            },
        abort.signal,
      );
      if (abort.signal.aborted || !alive.current) return;
      if (result.retryAfter) {
        setNotice('Try again in ' + result.retryAfter + ' seconds.');
        return;
      }
      await client.cancelQueries({ queryKey, exact: true });
      if (abort.signal.aborted || !alive.current) return;
      client.setQueryData(queryKey, result);
      setDraft(
        upload
          ? snapshot.name !== (result.brandName ?? '')
            ? { version: result.version, name: snapshot.name }
            : null
          : snapshot.file
            ? { version: result.version, name: result.brandName ?? '', file: snapshot.file }
            : null,
      );
      setNotice(upload ? 'Password-page logo saved.' : 'Password-page branding saved.');
    } catch (error) {
      if (alive.current && !abort.signal.aborted) {
        setBlocked(true);
        setNotice((error as Error).message + ' Reload settings before another write.');
      }
    } finally {
      if (alive.current && !abort.signal.aborted) setBusy(false);
    }
  };
  if (query.isPending) return <p role="status">Loading password-page branding…</p>;
  if (query.isError || !profile)
    return (
      <section className="space-y-2 border-t pt-4">
        <p role="alert">Password branding unavailable. {query.error?.message}</p>
        <Button variant="outline" onClick={() => void reload()}>
          Reload password branding
        </Button>
      </section>
    );
  const image = editable && draft?.file ? draft.file.data : preview.data;
  return (
    <section aria-label="Password-page branding" className="space-y-4 border-t pt-4">
      <h3 className="font-medium">Password-page branding</h3>
      <p className="text-sm text-muted-foreground">
        This public label and logo appear before a visitor unlocks the link. They are separate from
        social previews and QR artwork.
      </p>
      <div>
        <Label htmlFor={fieldId + '-name'}>Public brand name</Label>
        <Input
          id={fieldId + '-name'}
          value={editable && draft ? draft.name : (profile.brandName ?? '')}
          disabled={!editable || busy || reading}
          maxLength={80}
          onChange={(event) => {
            setDraft((previous) => ({
              ...(previous ?? { version: profile.version, name: '' }),
              name: event.target.value,
            }));
            setNotice('');
          }}
        />
      </div>
      {editable && (
        <div className="space-y-2">
          <Label htmlFor={fieldId + '-logo'}>Choose a password-page logo</Label>
          <Input
            id={fieldId + '-logo'}
            type="file"
            accept="image/png,image/jpeg"
            disabled={busy || reading || blocked}
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = '';
              void select(file);
            }}
          />
          <p className="text-xs text-muted-foreground">
            PNG or JPG, up to 1.5 MB and 1024 pixels per dimension. Save the name and upload the
            selected logo separately.
          </p>
        </div>
      )}
      <div className="space-y-2 rounded-container border p-4">
        <p className="text-xs text-muted-foreground">
          {editable && draft ? 'Draft branding preview' : 'Saved public branding preview'}
        </p>
        {image && !(editable && draft?.clear) && (
          <img
            src={image}
            alt="Password-page logo preview"
            className="max-h-24 max-w-48 object-contain"
          />
        )}
        {preview.isError && !draft?.file && (
          <p className="text-sm">
            The saved logo could not be verified. The public password form remains usable.
          </p>
        )}
        <p className="font-medium break-words">
          {editable && draft ? draft.name : profile.brandName}
        </p>
        <p>Protected link</p>
        <p className="text-sm text-muted-foreground">Enter the password to open this link.</p>
      </div>
      {reading && <p role="status">Checking logo bytes and dimensions…</p>}
      {changed && (
        <p role="alert">Branding changed while you were editing. Reload before saving.</p>
      )}
      {notice && (
        <p role="status" className="text-sm break-words">
          {notice}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        {editable && (
          <>
            <Button
              disabled={
                busy ||
                reading ||
                blocked ||
                changed ||
                !draft ||
                (draft.name === (profile.brandName ?? '') && !draft.clear)
              }
              onClick={() => void save()}
            >
              {draft?.clear ? 'Confirm name and logo removal' : 'Save public name'}
            </Button>
            {draft?.file && (
              <Button
                disabled={busy || reading || blocked || changed}
                onClick={() => void save(true)}
              >
                Upload selected logo
              </Button>
            )}
            {profile.logoAsset && !draft?.clear && (
              <Button
                variant="outline"
                disabled={busy || reading}
                onClick={() =>
                  setDraft((previous) => ({
                    ...(previous ?? { version: profile.version, name: profile.brandName ?? '' }),
                    clear: true,
                    file: undefined,
                  }))
                }
              >
                Remove saved logo
              </Button>
            )}
          </>
        )}
        <Button variant="outline" disabled={busy || reading} onClick={() => void reload()}>
          Reload settings
        </Button>
      </div>
      {!editable && (
        <p className="text-sm text-muted-foreground">
          Edit access to this link is required to change password-page branding.
        </p>
      )}
    </section>
  );
}
