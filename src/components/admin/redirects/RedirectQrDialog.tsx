import { useState } from 'react';
import {
  DEFAULT_QR_STYLE,
  qrStyleError,
  generateQr,
  qrTrackingUrl,
  type QrStyle,
} from '@/lib/redirects/qr';
import { QrStyleFields } from './QrStyleFields';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';

function downloadQr(url: string, name: string) {
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = name;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
}

export function QrExport({
  url,
  managedShortLink = false,
}: {
  url: string;
  managedShortLink?: boolean;
}) {
  const [style, setStyle] = useState<QrStyle>({ ...DEFAULT_QR_STYLE });
  const error = qrStyleError(style);
  const qr = useQuery({
    queryKey: ['redirect-qr', url, style, managedShortLink],
    staleTime: Infinity,
    retry: false,
    enabled: !error,
    queryFn: async () => {
      return generateQr(qrTrackingUrl(url, managedShortLink), style);
    },
  });
  return (
    <div className="space-y-4">
      <p className="break-all font-mono text-xs">{url}</p>
      <QrStyleFields style={style} setStyle={setStyle} />
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {!error && qr.isPending && <p role="status">Generating QR code…</p>}
      {!error && qr.isError && (
        <p role="alert" className="text-destructive">
          {qr.error instanceof Error
            ? qr.error.message
            : 'Could not generate this QR code. Try a shorter link.'}
        </p>
      )}
      {!error && qr.data && (
        <img
          src={qr.data.png}
          width={256}
          height={256}
          alt={`QR code for ${url}`}
          className="mx-auto max-w-full"
        />
      )}
      <div className="flex flex-wrap gap-2">
        <Button
          variant="outline"
          size="sm"
          onClick={() =>
            void navigator.clipboard
              .writeText(url)
              .then(() => toast.success('Link copied'))
              .catch(() => toast.error('Could not copy link'))
          }
        >
          Copy link
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={!!error || !qr.data}
          onClick={() => qr.data && downloadQr(qr.data.png, 'queerguide-qr.png')}
        >
          Download PNG
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={!!error || !qr.data}
          onClick={() => qr.data && downloadQr(qr.data.jpg, 'queerguide-qr.jpg')}
        >
          Download JPG
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={!!error || !qr.data}
          onClick={() => {
            if (!qr.data) return;
            void (async () => {
              try {
                if (!navigator.clipboard?.write || typeof ClipboardItem === 'undefined')
                  throw new Error('Image clipboard unavailable');
                const blob = await (await fetch(qr.data!.png)).blob();
                await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
                toast.success('QR image copied');
              } catch {
                toast.error('Could not copy the image. Download PNG instead.');
              }
            })();
          }}
        >
          Copy image
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={!!error || !qr.data}
          onClick={() =>
            qr.data &&
            void navigator.clipboard
              .writeText(qr.data.png)
              .then(() => toast.success('QR data URL copied'))
              .catch(() => toast.error('Could not copy image URL'))
          }
        >
          Copy image data URL
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={!!error || !qr.data}
          onClick={() => {
            if (!qr.data) return;
            const objectUrl = URL.createObjectURL(
              new Blob([qr.data.svg], { type: 'image/svg+xml' }),
            );
            downloadQr(objectUrl, 'queerguide-qr.svg');
            setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
          }}
        >
          Download SVG
        </Button>
      </div>
    </div>
  );
}

export function RedirectQrDialog({
  url,
  onClose,
  managedShortLink = false,
}: {
  url: string;
  onClose: () => void;
  managedShortLink?: boolean;
}) {
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Share a QR code</DialogTitle>
          <DialogDescription>
            The QR code opens this URL. Create a tracked link to collect visit analytics.
          </DialogDescription>
        </DialogHeader>
        <QrExport url={url} managedShortLink={managedShortLink} />
      </DialogContent>
    </Dialog>
  );
}
