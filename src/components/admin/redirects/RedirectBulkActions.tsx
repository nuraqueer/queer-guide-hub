import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useRedirectWorkspace } from '@/hooks/useRedirectWorkspace';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';

export function RedirectBulkActions({
  rows,
  onClear,
  onExport,
  onBusy,
}: {
  rows: InventoryRedirect[];
  onClear: () => void;
  onExport: () => void;
  onBusy?: (busy: boolean) => void;
}) {
  const workspace = useRedirectWorkspace(),
    client = useQueryClient();
  const [action, setAction] = useState<'archive' | 'restore' | 'folder' | 'add-tag' | 'remove-tag'>(
    'archive',
  );
  const [value, setValue] = useState(''),
    [busy, setBusy] = useState(false),
    [error, setError] = useState('');
  const [confirm, setConfirm] = useState(false),
    [phrase, setPhrase] = useState('');
  const deletable =
    rows.length > 0 && rows.every((row) => row.manualId && row.source.startsWith('/go/'));
  const apply = async () => {
    setBusy(true);
    onBusy?.(true);
    setError('');
    try {
      await workspace.bulk.mutateAsync({
        keys: rows.map((row) => row.id),
        action,
        value: value || null,
      });
      onClear();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Bulk change failed');
    } finally {
      setBusy(false);
      onBusy?.(false);
    }
  };
  const remove = async () => {
    if (!deletable || phrase !== 'DELETE' || busy) return;
    setBusy(true);
    onBusy?.(true);
    setError('');
    try {
      const { data, error: deleteError } = await supabase.functions.invoke(
        'redirect-api/links/bulk',
        { body: { operations: rows.map((row) => ({ operation: 'delete', id: row.manualId })) } },
      );
      if (deleteError || data?.error) throw new Error(data?.error ?? deleteError?.message);
      if (
        !Array.isArray(data?.data) ||
        data.data.length !== rows.length ||
        data.data.some((entry: { deleted?: boolean }) => entry.deleted !== true)
      )
        throw new Error('Deletion response was incomplete; refresh the list before retrying.');
      await Promise.all([
        client.invalidateQueries({ queryKey: ['redirect-link-workspace'] }),
        client.invalidateQueries({ queryKey: ['cms-content-list'] }),
      ]);
      setConfirm(false);
      setPhrase('');
      onClear();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not delete links');
    } finally {
      setBusy(false);
      onBusy?.(false);
    }
  };
  return (
    <div className="mb-4 space-y-2 rounded-element border p-4" aria-label="Bulk redirect actions">
      <p className="text-sm font-medium">{rows.length} selected · maximum 100</p>
      <fieldset disabled={busy} className="flex flex-wrap items-center gap-2">
        <select
          aria-label="Bulk action"
          className="h-9 rounded-element border bg-background px-4 text-sm"
          value={action}
          onChange={(event) => {
            setAction(event.target.value as typeof action);
            setValue('');
            setError('');
          }}
        >
          <option value="archive">Archive</option>
          <option value="restore">Restore</option>
          <option value="folder">Move to folder</option>
          <option value="add-tag">Add tag</option>
          <option value="remove-tag">Remove tag</option>
        </select>
        {action === 'folder' && (
          <select
            aria-label="Bulk folder"
            className="h-9 rounded-element border bg-background px-4 text-sm"
            value={value}
            onChange={(event) => setValue(event.target.value)}
          >
            <option value="">Unfiled</option>
            {workspace.data?.folders.map((folder) => (
              <option key={folder.id} value={folder.id}>
                {folder.name}
              </option>
            ))}
          </select>
        )}
        {action.endsWith('tag') && (
          <select
            aria-label="Bulk tag"
            className="h-9 rounded-element border bg-background px-4 text-sm"
            value={value}
            onChange={(event) => setValue(event.target.value)}
          >
            <option value="">Choose tag</option>
            {workspace.data?.tags.map((tag) => (
              <option key={tag.id} value={tag.id}>
                {tag.name}
              </option>
            ))}
          </select>
        )}
        <Button
          size="sm"
          onClick={() => void apply()}
          disabled={!workspace.data || (action.endsWith('tag') && !value)}
        >
          Apply to selected
        </Button>
        <Button size="sm" variant="outline" onClick={onExport}>
          Export selected CSV
        </Button>
        <Button
          size="sm"
          variant="outline"
          disabled={!deletable}
          onClick={() => {
            setConfirm(true);
            setPhrase('');
            setError('');
          }}
        >
          Delete selected links
        </Button>
        <Button size="sm" variant="ghost" onClick={onClear}>
          Clear selection
        </Button>
      </fieldset>
      <p className="text-xs text-muted-foreground">
        Archiving hides redirects from the active view and keeps their URLs working. Folder and tag
        changes preserve comments and other tags. Deletion is available for managed short links.
      </p>
      {busy && (
        <p role="status" className="text-sm">
          Applying bulk change…
        </p>
      )}
      {error && !confirm && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <Dialog
        open={confirm}
        onOpenChange={(open) => {
          if (!busy) setConfirm(open);
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete {rows.length} short links?</DialogTitle>
            <DialogDescription>
              The selected links and their analytics history will be permanently deleted. Existing
              donation records are retained. Type DELETE to confirm.
            </DialogDescription>
          </DialogHeader>
          <ul className="max-h-48 overflow-auto text-sm">
            {rows.map((row) => (
              <li key={row.id} className="break-words">
                {row.source}
              </li>
            ))}
          </ul>
          <Input
            aria-label="Confirm link deletion"
            value={phrase}
            disabled={busy}
            onChange={(event) => setPhrase(event.target.value)}
          />
          {error && (
            <p role="alert" className="text-destructive">
              {error}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button variant="outline" disabled={busy} onClick={() => setConfirm(false)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              disabled={busy || phrase !== 'DELETE'}
              onClick={() => void remove()}
            >
              Permanently delete
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
