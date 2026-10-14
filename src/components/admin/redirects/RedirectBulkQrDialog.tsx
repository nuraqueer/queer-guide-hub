import { useQrExportStyle } from '@/hooks/useQrExportStyle';
import { qrAppearance } from '@/lib/redirects/qrLogos';
import { QrExportLogoChoice } from './QrExportLogoChoice';
import { useAuth } from '@/hooks/useAuth';
import { useRedirectBulkQrStyles } from '@/hooks/useRedirectBulkQrStyles';
import { useEffect, useRef, useState, type SetStateAction } from 'react';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { buildQrBundle, type QrBundleFormat } from '@/lib/redirects/qrBundle';
import { DEFAULT_QR_STYLE, qrStyleError, type QrStyle } from '@/lib/redirects/qr';
import { QrStyleFields } from './QrStyleFields';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
export function RedirectBulkQrDialog({
  rows,
  onClose,
}: {
  rows: InventoryRedirect[];
  onClose: () => void;
}) {
  const { user } = useAuth();
  const scope = JSON.stringify([user?.id, rows.map((row) => row.id)]);
  const [standardScope, setStandardScope] = useState<string | null>(null);
  const edits = useQrExportStyle(scope);
  const standard = standardScope === scope;
  const presets = useRedirectBulkQrStyles(rows, standard || edits.skipLogos);
  const ready = standard || (presets.isSuccess && !presets.isFetching);
  const baseline = standard
    ? DEFAULT_QR_STYLE
    : (presets.data?.get(rows[0]?.id) ?? DEFAULT_QR_STYLE);
  const style = edits.compose(baseline);
  const [format, setFormat] = useState<QrBundleFormat>('png');
  const [bundle, setBundle] = useState<Awaited<ReturnType<typeof buildQrBundle>> | null>(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(''),
    [progress, setProgress] = useState(0);
  const identity = JSON.stringify([
    scope,
    format,
    standard,
    qrAppearance(style),
    style.logoIdentity,
    presets.data
      ? [...presets.data].map(([id, saved]) => [id, qrAppearance(saved), saved.logoIdentity])
      : null,
  ]);
  const [bundleIdentity, setBundleIdentity] = useState<string | null>(null);
  const activeBundle = bundleIdentity === identity ? bundle : null;
  const [logoBusyScope, setLogoBusyScope] = useState<string | null>(null);
  const logoBusy = logoBusyScope === scope;
  const setLogoBusy = (busy: boolean) =>
    setLogoBusyScope((previous) => (busy ? scope : previous === scope ? null : previous));
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  const close = () => {
    controller.current?.abort();
    onClose();
  };
  const changeStyle = (value: SetStateAction<QrStyle>) => {
    setBundle(null);
    setError('');
    edits.change(baseline, value);
  };
  const prepare = async () => {
    if (controller.current || logoBusy || !ready) return;
    const run = new AbortController();
    controller.current = run;
    setBusy(true);
    setBundle(null);
    setError('');
    setProgress(0);
    try {
      const result = await buildQrBundle(rows, style, format, {
        signal: run.signal,
        stylesById: new Map(
          rows.map((row) => [
            row.id,
            edits.compose(standard ? DEFAULT_QR_STYLE : presets.data!.get(row.id)!),
          ]),
        ),
        onProgress: (completed) => setProgress(completed),
      });
      if (!run.signal.aborted) {
        setBundle(result);
        setBundleIdentity(identity);
      }
    } catch (err) {
      if (!run.signal.aborted)
        setError(err instanceof Error ? err.message : 'Could not prepare QR export');
    } finally {
      controller.current = null;
      setBusy(false);
    }
  };
  const download = () => {
    if (!activeBundle || busy || !ready) return;
    const url = URL.createObjectURL(new Blob([activeBundle.bytes], { type: 'application/zip' }));
    try {
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = 'queerguide-qr-codes.zip';
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
    } finally {
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
  };
  const styleError = qrStyleError(style);
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) close();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Export {rows.length} QR codes</DialogTitle>
          <DialogDescription>
            One ZIP containing the selected codes and a CSV manifest. Every code is scan-verified
            before download. Managed short links include QR tracking.
          </DialogDescription>
        </DialogHeader>
        {!ready && !presets.isError && <p role="status">Loading saved QR styles…</p>}
        {presets.isError && !standard && (
          <div className="space-y-2">
            <p role="alert">Could not load saved QR styles.</p>
            <Button variant="outline" onClick={() => void presets.refetch()}>
              Retry saved QR styles
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                edits.reset();
                setBundle(null);
                setStandardScope(scope);
              }}
            >
              Use standard style for this export
            </Button>
          </div>
        )}
        <p className="text-sm">
          {edits.hasAppearance
            ? 'One custom appearance applies to this selection.'
            : standard
              ? 'Standard appearance applies to this export.'
              : 'Each code uses its saved domain or workspace appearance. Controls show the first code; editing applies one appearance while preserving each saved logo.'}
        </p>
        {(edits.hasAppearance || standard) && (
          <Button
            variant="ghost"
            disabled={busy}
            onClick={() => {
              edits.savedAppearance();
              setStandardScope(null);
              setBundle(null);
              void presets.refetch();
            }}
          >
            Use saved appearance
          </Button>
        )}
        <QrExportLogoChoice
          mode={standard && edits.logoMode === 'saved' ? 'none' : edits.logoMode}
          hide={edits.hideLogo}
          saved={() => {
            edits.savedLogo();
            setStandardScope(null);
            void presets.refetch();
          }}
          disabled={busy || logoBusy}
        />
        <QrStyleFields
          key={scope}
          style={style}
          setStyle={changeStyle}
          disabled={busy || !ready}
          onBusy={setLogoBusy}
        />
        <label className="space-y-2 text-sm">
          Format
          <select
            aria-label="Bulk QR format"
            className="h-10 w-full rounded-element border bg-background px-4"
            disabled={busy}
            value={format}
            onChange={(event) => {
              setFormat(event.target.value as QrBundleFormat);
              setBundle(null);
              setError('');
            }}
          >
            <option value="png">PNG</option>
            <option value="jpg">JPG</option>
            <option value="svg">SVG</option>
            <option value="all">PNG, JPG and SVG</option>
          </select>
        </label>
        {(error || styleError) && (
          <p role="alert" className="text-sm text-destructive">
            {error || styleError}
          </p>
        )}
        {busy && (
          <p role="status" className="text-sm">
            {progress} / {rows.length} codes verified
            {progress === rows.length ? ' · Packaging ZIP…' : '…'}
          </p>
        )}
        {ready && activeBundle && (
          <>
            <img
              src={activeBundle.firstPreview}
              width={256}
              height={256}
              className="mx-auto max-w-full"
              alt="First verified QR code in this export"
            />
            <p role="status" className="text-sm">
              {activeBundle.count} verified codes ready ·{' '}
              {(activeBundle.bytes.byteLength / 1024 / 1024).toFixed(1)} MB
            </p>
          </>
        )}
        <p className="text-xs text-muted-foreground">
          Exports are prepared locally. Maximum 100 links and 64 MB. If one code fails, fix its
          style or selection and prepare the ZIP again.
        </p>
        <div className="flex flex-wrap gap-2">
          <Button
            disabled={!ready || busy || logoBusy || !!styleError}
            onClick={() => void prepare()}
          >
            Prepare QR ZIP
          </Button>
          <Button
            variant="outline"
            disabled={!ready || busy || logoBusy || !activeBundle}
            onClick={download}
          >
            Download QR ZIP
          </Button>
          {busy && (
            <Button variant="outline" onClick={() => controller.current?.abort()}>
              Cancel generation
            </Button>
          )}
          <Button variant="ghost" onClick={close}>
            Close
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
