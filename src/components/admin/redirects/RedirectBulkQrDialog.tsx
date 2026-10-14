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
  const [style, setStyle] = useState<QrStyle>({ ...DEFAULT_QR_STYLE }),
    [format, setFormat] = useState<QrBundleFormat>('png');
  const [bundle, setBundle] = useState<Awaited<ReturnType<typeof buildQrBundle>> | null>(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(''),
    [progress, setProgress] = useState(0);
  const [logoBusy, setLogoBusy] = useState(false);
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  const close = () => {
    controller.current?.abort();
    onClose();
  };
  const changeStyle = (value: SetStateAction<QrStyle>) => {
    setBundle(null);
    setError('');
    setStyle(value);
  };
  const prepare = async () => {
    if (controller.current || logoBusy) return;
    const run = new AbortController();
    controller.current = run;
    setBusy(true);
    setBundle(null);
    setError('');
    setProgress(0);
    try {
      const result = await buildQrBundle(rows, style, format, {
        signal: run.signal,
        onProgress: (completed) => setProgress(completed),
      });
      if (!run.signal.aborted) setBundle(result);
    } catch (err) {
      if (!run.signal.aborted)
        setError(err instanceof Error ? err.message : 'Could not prepare QR export');
    } finally {
      controller.current = null;
      setBusy(false);
    }
  };
  const download = () => {
    if (!bundle || busy) return;
    const url = URL.createObjectURL(new Blob([bundle.bytes], { type: 'application/zip' }));
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
        <QrStyleFields style={style} setStyle={changeStyle} disabled={busy} onBusy={setLogoBusy} />
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
        {bundle && (
          <>
            <img
              src={bundle.firstPreview}
              width={256}
              height={256}
              className="mx-auto max-w-full"
              alt="First verified QR code in this export"
            />
            <p role="status" className="text-sm">
              {bundle.count} verified codes ready ·{' '}
              {(bundle.bytes.byteLength / 1024 / 1024).toFixed(1)} MB
            </p>
          </>
        )}
        <p className="text-xs text-muted-foreground">
          Exports are prepared locally. Maximum 100 links and 64 MB. If one code fails, fix its
          style or selection and prepare the ZIP again.
        </p>
        <div className="flex flex-wrap gap-2">
          <Button disabled={busy || logoBusy || !!styleError} onClick={() => void prepare()}>
            Prepare QR ZIP
          </Button>
          <Button variant="outline" disabled={busy || logoBusy || !bundle} onClick={download}>
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
