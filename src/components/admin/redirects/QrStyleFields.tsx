import { useState, type Dispatch, type SetStateAction } from 'react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import type { QrStyle } from '@/lib/redirects/qr';
export function QrStyleFields({
  style,
  setStyle,
  disabled = false,
  onBusy,
}: {
  style: QrStyle;
  setStyle: Dispatch<SetStateAction<QrStyle>>;
  disabled?: boolean;
  onBusy?: (busy: boolean) => void;
}) {
  const [uploadError, setUploadError] = useState('');
  const [reading, setReading] = useState(false);
  const changeStyle = <K extends keyof QrStyle>(key: K, value: QrStyle[K]) =>
    setStyle((previous) => ({ ...previous, [key]: value }));
  const loadLogo = async (file?: File) => {
    setUploadError('');
    if (!file) return;
    if (!['image/png', 'image/jpeg'].includes(file.type) || file.size > 1.5 * 1024 * 1024) {
      setUploadError('Use a PNG or JPG logo smaller than 1.5 MB.');
      return;
    }
    setReading(true);
    onBusy?.(true);
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
    } finally {
      setReading(false);
      onBusy?.(false);
    }
  };
  return (
    <fieldset disabled={disabled || reading} className="space-y-4">
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
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = '';
              void loadLogo(file);
            }}
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
      {reading && <p role="status">Preparing logo…</p>}
      {uploadError && (
        <p role="alert" className="text-sm text-destructive">
          {uploadError}
        </p>
      )}
    </fieldset>
  );
}
