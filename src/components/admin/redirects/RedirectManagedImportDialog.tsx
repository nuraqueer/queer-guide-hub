import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import {
  managedImportCsv,
  MANAGED_IMPORT_MAX_BYTES,
  IMPORT_HEADERS,
  type ImportMode,
  type ImportOperation,
} from '@/lib/redirects/importCsv';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Input } from '@/components/ui/input';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
export function RedirectManagedImportDialog({
  onClose,
  onPathImport,
}: {
  onClose: () => void;
  onPathImport: () => void;
}) {
  const client = useQueryClient();
  const [text, setText] = useState(''),
    [mode, setMode] = useState<ImportMode>('create'),
    [review, setReview] = useState<ImportOperation[] | null>(null),
    [error, setError] = useState(''),
    [busy, setBusy] = useState(false),
    [success, setSuccess] = useState<number | null>(null);
  const edit = (value: string) => {
    setText(value);
    setReview(null);
    setSuccess(null);
    setError('');
  };
  const preview = () => {
    setError('');
    try {
      setReview(managedImportCsv(text, mode));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Invalid CSV');
      setReview(null);
    }
  };
  const apply = async () => {
    if (!review || busy || success !== null) return;
    setBusy(true);
    setError('');
    try {
      const { data, error: importError } = await supabase.functions.invoke(
        'redirect-api/links/bulk',
        { body: { operations: review } },
      );
      if (importError || data?.error) throw new Error(data?.error ?? importError?.message);
      if (!Array.isArray(data?.data) || data.data.length !== review.length)
        throw new Error('Import response was incomplete. Refresh the list before retrying.');
      setSuccess(review.length);
      await Promise.all([
        client.invalidateQueries({ queryKey: ['cms-content-list'] }),
        client.invalidateQueries({ queryKey: ['redirect-link-workspace'] }),
      ]);
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : 'Could not confirm the import. Refresh before retrying.',
      );
    } finally {
      setBusy(false);
    }
  };
  const loadFile = async (file?: File) => {
    if (!file) return;
    setReview(null);
    setSuccess(null);
    if (file.size > MANAGED_IMPORT_MAX_BYTES) {
      setError('CSV must be at most 2.1 MB');
      return;
    }
    setBusy(true);
    setError('');
    try {
      edit(await file.text());
    } catch {
      setError('Could not read this CSV file');
    } finally {
      setBusy(false);
    }
  };
  const template = () => {
    const url = URL.createObjectURL(
      new Blob(
        [
          IMPORT_HEADERS.join(',') +
            '\r\n,pride-campaign,https://example.com/events,302,true,false,PRESERVE,,,,,,\r\n',
        ],
        { type: 'text/csv;charset=utf-8' },
      ),
    );
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'redirect-managed-import-template.csv';
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-3xl min-w-0 overflow-y-auto [&>*]:min-w-0">
        <DialogHeader>
          <DialogTitle>Import managed short links</DialogTitle>
          <DialogDescription>
            Review up to 100 rows, then apply one atomic batch. Create adds new links; update uses
            IDs; upsert creates or updates by slug. Blank fields preserve existing values.
          </DialogDescription>
        </DialogHeader>
        <fieldset disabled={busy} className="min-w-0 space-y-4">
          <label className="space-y-2 text-sm">
            Mode
            <select
              aria-label="Managed import mode"
              className="h-10 w-full rounded-element border bg-background px-4"
              value={mode}
              onChange={(event) => {
                setMode(event.target.value as ImportMode);
                setReview(null);
                setSuccess(null);
                setError('');
              }}
            >
              <option value="create">Create new links</option>
              <option value="update">Update by ID</option>
              <option value="upsert">Create or update by slug</option>
            </select>
          </label>
          <Input
            aria-label="Upload managed CSV"
            type="file"
            accept=".csv,text/csv"
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = '';
              void loadFile(file);
            }}
          />
          <Textarea
            aria-label="Managed links CSV"
            className="font-mono text-xs"
            maxLength={MANAGED_IMPORT_MAX_BYTES}
            rows={8}
            placeholder={'slug,target,statusCode\npride-campaign,https://example.com/events,302'}
            value={text}
            onChange={(event) => edit(event.target.value)}
          />
          <p className="text-xs text-muted-foreground">
            Quoted commas, escaped quotes and multiline comments are supported. Snake-case headers
            are accepted. JSON objects/arrays are used for queryOverride, utmDefaults and tagIds.
            Exported commentJson cells use JSON strings. Use null to clear nullable
            folder/expiry/query-default fields. ID is used only in update mode. Upsert requires slug
            and target.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={template}>
              Download CSV template
            </Button>
            <Button variant="ghost" onClick={onPathImport}>
              Import path rules instead
            </Button>
            <Button disabled={!text.trim()} onClick={preview}>
              Review import
            </Button>
          </div>
        </fieldset>
        {review && (
          <div className="min-w-0 space-y-2">
            <p className="text-sm font-medium">
              {review.length} rows ready for {mode}
            </p>
            <div
              className="max-h-64 min-w-0 max-w-full overflow-auto rounded-element border"
              role="region"
              aria-label="Managed CSV review"
              tabIndex={0}
            >
              <table className="w-full min-w-[36rem] text-left text-xs">
                <thead>
                  <tr>
                    <th className="p-2">Row</th>
                    <th className="p-2">Identity</th>
                    <th className="p-2">Destination</th>
                    <th className="p-2">Fields</th>
                  </tr>
                </thead>
                <tbody>
                  {review.map((op, index) => (
                    <tr key={index}>
                      <td className="p-2">{index + 2}</td>
                      <td className="max-w-64 break-words p-2 font-mono">
                        {op.id ?? String(op.data.slug ?? 'Random slug')}
                      </td>
                      <td className="max-w-64 break-words p-2">
                        {String(op.data.target ?? 'Preserve destination')}
                      </td>
                      <td className="max-w-64 break-words p-2">
                        <details>
                          <summary>{Object.keys(op.data).join(', ')}</summary>
                          <pre className="whitespace-pre-wrap break-words">
                            {JSON.stringify(op.data, null, 2)}
                          </pre>
                        </details>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="text-xs text-muted-foreground">
              Only the fields listed are sent. An invalid row or slug conflict rolls back the whole
              batch. A network failure may leave the outcome unknown; refresh before retrying.
            </p>
            <Button disabled={busy || success !== null} onClick={() => void apply()}>
              Apply {review.length} {review.length === 1 ? 'row' : 'rows'}
            </Button>
          </div>
        )}
        {busy && <p role="status">Processing import…</p>}
        {success !== null && (
          <p role="status">
            Applied {success} {success === 1 ? 'row' : 'rows'} successfully.
          </p>
        )}
        {error && (
          <p role="alert" className="break-words text-sm text-destructive">
            {error}
          </p>
        )}
        <Button variant="outline" disabled={busy} onClick={onClose}>
          Close import
        </Button>
      </DialogContent>
    </Dialog>
  );
}
