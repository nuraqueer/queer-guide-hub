import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { useRedirectWorkspace, type LinkMetadata } from '@/hooks/useRedirectWorkspace';
import type { InventoryRedirect } from '@/lib/redirects/inventory';

export function RedirectOrganizationDialog({
  row,
  onClose,
}: {
  row: InventoryRedirect;
  onClose: () => void;
}) {
  const workspace = useRedirectWorkspace();
  const existing = workspace.data?.metadata.get(row.id);
  const [metadata, setMetadata] = useState<LinkMetadata>(
    existing ?? { redirect_key: row.id, folder_id: null, comment: '', tagIds: [] },
  );
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="max-w-xl">
        <DialogHeader>
          <DialogTitle>Organize redirect</DialogTitle>
          <DialogDescription>{row.source}</DialogDescription>
        </DialogHeader>
        {workspace.isError && (
          <p role="alert">Could not load folders and tags. {workspace.error.message}</p>
        )}
        <form
          className="space-y-4"
          onSubmit={(event) => {
            event.preventDefault();
            void workspace.assignment
              .mutateAsync(metadata)
              .then(onClose)
              .catch(() => {});
          }}
        >
          <div className="space-y-2">
            <Label htmlFor="redirect-folder">Folder</Label>
            <select
              id="redirect-folder"
              className="w-full rounded-element border bg-background p-2 text-sm"
              value={metadata.folder_id ?? ''}
              onChange={(event) =>
                setMetadata({ ...metadata, folder_id: event.target.value || null })
              }
            >
              <option value="">Unfiled</option>
              {workspace.data?.folders.map((folder) => (
                <option key={folder.id} value={folder.id}>
                  {folder.name}
                </option>
              ))}
            </select>
          </div>
          <fieldset>
            <legend className="mb-2 font-medium">Tags</legend>
            <div className="flex flex-wrap gap-4">
              {workspace.data?.tags.map((tag) => (
                <label key={tag.id} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={metadata.tagIds.includes(tag.id)}
                    onChange={(event) =>
                      setMetadata({
                        ...metadata,
                        tagIds: event.target.checked
                          ? [...metadata.tagIds, tag.id]
                          : metadata.tagIds.filter((id) => id !== tag.id),
                      })
                    }
                  />
                  {tag.name}
                </label>
              ))}
            </div>
          </fieldset>
          <div className="space-y-2">
            <Label htmlFor="redirect-comment">Team comment</Label>
            <Textarea
              id="redirect-comment"
              value={metadata.comment}
              maxLength={10000}
              onChange={(event) => setMetadata({ ...metadata, comment: event.target.value })}
            />
            <p className="text-xs text-muted-foreground">
              Visible to your team. URLs will be clickable in the list.
            </p>
          </div>
          {workspace.assignment.isError && (
            <p role="alert" className="text-destructive">
              {workspace.assignment.error.message}
            </p>
          )}
          <Button type="submit" disabled={!workspace.data || workspace.assignment.isPending}>
            {workspace.assignment.isPending ? 'Saving…' : 'Save organization'}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}
