import { validateTarget } from '@/lib/redirects/validation';
import { parseRedirectCsv } from '@/lib/redirects/importCsv';
import { useState } from 'react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Textarea } from '@/components/ui/textarea';
import { Alert, AlertDescription } from '@/components/ui/alert';

interface BulkImportDialogProps {
  open: boolean;
  onClose: () => void;
  onImport: (
    items: Array<{
      slug?: string;
      source_path?: string;
      target: string;
      status_code?: number;
      is_enabled?: boolean;
    }>,
  ) => Promise<{ success: number; errors: string[] }>;
}

export function BulkImportDialog({ open, onClose, onImport }: BulkImportDialogProps) {
  const [csvText, setCsvText] = useState('');
  const [result, setResult] = useState<{ success: number; errors: string[] } | null>(null);
  const [importing, setImporting] = useState(false);

  const handleImport = async () => {
    setImporting(true);
    setResult(null);
    try {
      const lines = parseRedirectCsv(csvText);
      const headers = lines[0].map((h) => h.trim().toLowerCase());
      const items = lines.slice(1).map((line, index) => {
        const values = line.map((v) => v.trim());
        const obj: Record<string, string | number | boolean | undefined> = {};
        headers.forEach((h, i) => {
          if (h === 'slug') obj.slug = values[i];
          if (h === 'source_path') obj.source_path = values[i];
          if (h === 'target') obj.target = values[i];
          if (h === 'status_code' && values[i]) {
            if (!/^(301|302|307|308)$/.test(values[i]))
              throw new Error('Row ' + (index + 2) + ': invalid HTTP status');
            obj.status_code = Number(values[i]);
          }
          if (h === 'is_enabled' && values[i]) {
            if (!['true', 'false', '1', '0'].includes(values[i].toLowerCase()))
              throw new Error('Row ' + (index + 2) + ': invalid enabled state');
            obj.is_enabled = ['true', '1'].includes(values[i].toLowerCase());
          }
        });
        const target = validateTarget(String(obj.target ?? ''));
        if (!target.valid) throw new Error('Row ' + (index + 2) + ': ' + target.error);
        return obj;
      });
      if (items.some((item) => !item.target))
        throw new Error('Every CSV row requires a destination');
      const res = await onImport(
        items as Array<{
          slug?: string;
          source_path?: string;
          target: string;
          status_code?: number;
          is_enabled?: boolean;
        }>,
      );
      setResult(res);
    } catch (err: unknown) {
      setResult({ success: 0, errors: [err instanceof Error ? err.message : 'Import failed'] });
    } finally {
      setImporting(false);
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        if (!o && !importing) onClose();
      }}
    >
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Bulk Import (CSV)</DialogTitle>
        </DialogHeader>
        <p className="text-sm text-muted-foreground mb-4">
          Paste CSV with headers: <code>slug,target,status_code,is_enabled</code> (for short links)
          or <code>source_path,target,status_code,is_enabled</code> (for path redirects).
        </p>
        <Textarea
          className="text-sm"
          rows={8}
          value={csvText}
          onChange={(e) => setCsvText(e.target.value)}
          placeholder={`slug,target,status_code\npride-zrh,/events/pride-zurich-2026,301\nnyc-guide,/city/new-york,302`}
          style={{ fontFamily: 'monospace' }}
        />
        {result && (
          <div className="mt-4">
            {result.success > 0 && (
              <Alert className="mb-2">
                <AlertDescription>Imported {result.success} redirect(s)</AlertDescription>
              </Alert>
            )}
            {result.errors.length > 0 && (
              <Alert variant="destructive">
                <AlertDescription>
                  {result.errors.map((e, i) => (
                    <div key={i}>{e}</div>
                  ))}
                </AlertDescription>
              </Alert>
            )}
          </div>
        )}
        <DialogFooter>
          <Button variant="outline" disabled={importing} onClick={onClose}>
            Close
          </Button>
          <Button onClick={handleImport} disabled={importing || !csvText.trim()}>
            {importing ? 'Importing...' : 'Import'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
