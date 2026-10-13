import { useState } from 'react';
import { DEFAULT_QR_STYLE, qrStyleError, generateQr, type QrStyle } from '@/lib/redirects/qr';
import { Input } from '@/components/ui/input';
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

export function QrExport({ url }: { url: string }) {
  const [style, setStyle] = useState<QrStyle>({ ...DEFAULT_QR_STYLE });
  const [uploadError, setUploadError] = useState('');
  const error = qrStyleError(style);
  const changeStyle = <K extends keyof QrStyle>(key: K, value: QrStyle[K]) =>
    setStyle((previous) => ({ ...previous, [key]: value }));
  const qr = useQuery({
    queryKey: ['redirect-qr', url, style],
    staleTime: Infinity,
    retry: false,
    enabled: !error,
    queryFn: async () => {
      return generateQr(url, style);
    },
  });
  const loadLogo = async (file?: File) => {
    setUploadError('');
    if (!file) return;
    if (!['image/png', 'image/jpeg'].includes(file.type) || file.size > 1.5 * 1024 * 1024) {
      setUploadError('Use a PNG or JPG logo smaller than 1.5 MB.');
      return;
    }
    try {
      const data = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result));
        reader.onerror = () => reject(new Error('Could not read this logo.'));
        reader.readAsDataURL(file);
      });
      const image = new Image();
      image.src = data;
      await image.decode();
      changeStyle('logo', data);
    } catch {
      setUploadError('Could not read this logo. Try another PNG or JPG.');
    }
  };
  return (
    <div className="space-y-4">
      <p className="break-all font-mono text-xs">{url}</p>
      <div className="grid grid-cols-2 gap-4">
        <label className="space-y-1 text-sm">
          Dots
          <select
            aria-label="QR dots"
            className="h-10 w-full rounded-element border bg-background px-4"
            value={style.dots}
            onChange={(event) => changeStyle('dots', event.target.value as QrStyle['dots'])}
          >
            <option value="square">Square</option>
            <option value="circle">Circle</option>
            <option value="joined">Joined</option>
          </select>
        </label>
        <label className="space-y-1 text-sm">
          Marker border
          <select
            aria-label="QR marker border"
            className="h-10 w-full rounded-element border bg-background px-4"
            value={style.border}
            onChange={(event) => changeStyle('border', event.target.value as QrStyle['border'])}
          >
            <option value="square">Square</option>
            <option value="rounded">Rounded</option>
            <option value="circle">Circle</option>
          </select>
        </label>
        <label className="space-y-1 text-sm">
          Marker center
          <select
            aria-label="QR marker center"
            className="h-10 w-full rounded-element border bg-background px-4"
            value={style.center}
            onChange={(event) => changeStyle('center', event.target.value as QrStyle['center'])}
          >
            <option value="square">Square</option>
            <option value="circle">Circle</option>
          </select>
        </label>
        <label htmlFor="qr-dot-color" className="space-y-1 text-sm">
          Dot color
          <Input
            id="qr-dot-color"
            aria-label="QR dot color"
            type="color"
            value={style.foreground}
            onChange={(event) => changeStyle('foreground', event.target.value)}
          />
        </label>
        <label htmlFor="qr-background-color" className="space-y-1 text-sm">
          Background color
          <Input
            id="qr-background-color"
            aria-label="QR background color"
            type="color"
            value={style.background}
            onChange={(event) => changeStyle('background', event.target.value)}
          />
        </label>
        <label htmlFor="qr-logo" className="space-y-1 text-sm">
          Logo (optional)
          <Input
            id="qr-logo"
            aria-label="QR logo"
            type="file"
            accept="image/png,image/jpeg"
            onChange={(event) => void loadLogo(event.target.files?.[0])}
          />
        </label>
      </div>
      {style.logo && (
        <Button variant="ghost" size="sm" onClick={() => changeStyle('logo', undefined)}>
          Remove logo
        </Button>
      )}
      <p className="text-xs text-muted-foreground">
        Keep strong contrast. Test your downloaded code with a phone before printing.
      </p>
      {(error || uploadError) && (
        <p role="alert" className="text-sm text-destructive">
          {error || uploadError}
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

export function RedirectQrDialog({ url, onClose }: { url: string; onClose: () => void }) {
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
        <QrExport url={url} />
      </DialogContent>
    </Dialog>
  );
}
