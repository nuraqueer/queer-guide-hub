import { PageContainer } from '@/components/layout/PageContainer';
import { useState } from 'react';
import { Navigate, useLocation } from 'react-router';
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '@/hooks/useAuth';
import { useMemberRedirectResources } from '@/hooks/useMemberRedirectResources';
import {
  memberRedirectApi,
  type MemberLink,
  type MemberResources,
} from '@/lib/redirects/memberApi';
import { managedLinksCsv } from '@/lib/redirects/importCsv';
import { CAMPAIGN_FIELDS } from '@/lib/redirects/linkTools';
import { manualRedirect, type InventoryRedirect } from '@/lib/redirects/inventory';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { RedirectQrDialog } from '@/components/admin/redirects/RedirectQrDialog';
import { RedirectPolicyDialog } from '@/components/admin/redirects/RedirectPolicyDialog';
import { RedirectManagedImportDialog } from '@/components/admin/redirects/RedirectManagedImportDialog';
import { MemberRedirectAnalyticsDialog } from '@/components/admin/redirects/RedirectAnalyticsDialog';
import { RedirectFolderAccess } from '@/components/admin/redirects/RedirectFolderAccess';
const CONTROL = 'w-full rounded-element border bg-background p-2 text-sm';
function inventory(link: MemberLink): InventoryRedirect {
  return manualRedirect({
    id: link.id,
    type: 'SHORT',
    slug: link.slug,
    target: link.target,
    status_code: link.statusCode,
    is_enabled: link.isEnabled,
    start_at: link.startsAt,
    end_at: link.expiresAt,
    click_count: link.clicks,
    click_limit: link.clickLimit,
    utm_defaults: link.utmDefaults,
    query_mode: link.queryMode,
    query_override: link.queryOverride,
    updated_at: link.updatedAt,
  });
}
function exportLinks(links: MemberLink[]) {
  const url = URL.createObjectURL(
    new Blob([managedLinksCsv(links as unknown as Record<string, unknown>[])], {
      type: 'text/csv;charset=utf-8',
    }),
  );
  const a = document.createElement('a');
  a.href = url;
  a.download = 'redirect-links.csv';
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function LinkEditor({
  link,
  prefill,
  resources,
  onSave,
  onClose,
}: {
  link?: MemberLink;
  prefill?: MemberLink;
  resources: MemberResources;
  onSave: (body: Record<string, unknown>) => Promise<unknown>;
  onClose: () => void;
}) {
  const initial = link ?? prefill;
  const [slug, setSlug] = useState(link?.slug ?? ''),
    [target, setTarget] = useState(initial?.target ?? ''),
    [folderId, setFolderId] = useState(
      initial?.folderId && resources.folders.some((f) => f.id === initial.folderId && f.canEdit)
        ? initial.folderId
        : '',
    ),
    [comment, setComment] = useState(initial?.comment ?? '');
  const [tags, setTags] = useState(initial?.tagIds ?? []),
    [utm, setUtm] = useState(initial?.utmDefaults ?? {}),
    [enabled, setEnabled] = useState(initial?.isEnabled ?? true);
  const [queryMode, setQueryMode] = useState(link?.queryMode ?? 'PRESERVE');
  const save = useMutation({
    mutationFn: () =>
      onSave({
        ...(slug ? { slug } : {}),
        target,
        folderId: folderId || null,
        comment,
        tagIds: tags,
        utmDefaults: utm,
        isEnabled: enabled,
        queryMode,
      }),
    onSuccess: onClose,
  });
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !save.isPending) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {link ? 'Edit link' : prefill ? 'Create from this link' : 'Create link'}
          </DialogTitle>
          <DialogDescription>
            Choose a destination, organize the link and apply campaign defaults.
          </DialogDescription>
        </DialogHeader>
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            save.mutate();
          }}
        >
          <fieldset disabled={save.isPending} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="member-link-target">Destination</Label>
              <Input
                id="member-link-target"
                required
                maxLength={8192}
                value={target}
                onChange={(e) => setTarget(e.target.value)}
                placeholder="https://example.com/register"
              />
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="member-link-slug">Short path</Label>
                <Input
                  id="member-link-slug"
                  required={!!link}
                  maxLength={64}
                  value={slug}
                  onChange={(e) => setSlug(e.target.value)}
                />
                <p className="text-xs text-muted-foreground">
                  {link
                    ? 'Use 3–64 lowercase letters, numbers or hyphens.'
                    : 'Leave empty for a random path.'}
                </p>
              </div>
              <div className="space-y-2">
                <Label htmlFor="member-link-folder">Folder</Label>
                <select
                  id="member-link-folder"
                  className={CONTROL}
                  value={folderId}
                  onChange={(e) => setFolderId(e.target.value)}
                >
                  <option value="">Unfiled</option>
                  {resources.folders
                    .filter((f) => f.canEdit)
                    .map((f) => (
                      <option key={f.id} value={f.id}>
                        {f.name}
                      </option>
                    ))}
                </select>
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="member-link-query">Destination query parameters</Label>
              <select
                id="member-link-query"
                className={CONTROL}
                value={queryMode}
                onChange={(e) => setQueryMode(e.target.value)}
              >
                <option value="PRESERVE">Preserve incoming parameters</option>
                <option value="DROP">Drop incoming parameters</option>
                {link?.queryMode === 'OVERRIDE' && (
                  <option value="OVERRIDE">Keep existing overrides</option>
                )}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="member-utm-template">Prefill campaign template</Label>
              <select
                id="member-utm-template"
                className={CONTROL}
                defaultValue=""
                onChange={(e) => {
                  const template = resources.templates.find((t) => t.id === e.target.value);
                  if (template) setUtm({ ...template.parameters });
                }}
              >
                <option value="">Choose a template</option>
                {resources.templates.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              {CAMPAIGN_FIELDS.map((field) => (
                <div key={field} className="space-y-2">
                  <Label htmlFor={'member-' + field}>{field}</Label>
                  <Input
                    id={'member-' + field}
                    maxLength={2000}
                    value={utm[field] ?? ''}
                    onChange={(e) =>
                      setUtm((current) => {
                        const next = { ...current };
                        if (e.target.value) next[field] = e.target.value;
                        else delete next[field];
                        return next;
                      })
                    }
                  />
                </div>
              ))}
            </div>
            <fieldset className="space-y-2">
              <legend className="text-sm font-medium">Tags</legend>
              <div className="flex flex-wrap gap-4">
                {resources.tags.map((tag) => (
                  <label key={tag.id} className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={tags.includes(tag.id)}
                      onChange={(e) =>
                        setTags(
                          e.target.checked ? [...tags, tag.id] : tags.filter((id) => id !== tag.id),
                        )
                      }
                    />
                    {tag.name}
                  </label>
                ))}
              </div>
            </fieldset>
            <div className="space-y-2">
              <Label htmlFor="member-link-comment">Team comment</Label>
              <Textarea
                id="member-link-comment"
                maxLength={10000}
                value={comment}
                onChange={(e) => setComment(e.target.value)}
              />
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={enabled}
                onChange={(e) => setEnabled(e.target.checked)}
              />
              Link enabled
            </label>
          </fieldset>
          {save.isError && (
            <p role="alert" className="text-destructive">
              {save.error.message}
            </p>
          )}
          <Button type="submit" disabled={save.isPending}>
            {save.isPending ? 'Saving…' : link ? 'Save link' : 'Create link'}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}
export function MemberWorkspaceContent({ userId }: { userId: string }) {
  const client = useQueryClient();
  const resources = useMemberRedirectResources(userId);
  const session = useQuery({
    queryKey: ['redirect-member', userId, 'session'],
    queryFn: () =>
      memberRedirectApi<{ role: 'owner' | 'member' | 'viewer'; label: string | null }>('/session'),
    retry: false,
  });
  const [search, setSearch] = useState(''),
    [folder, setFolder] = useState(''),
    [archive, setArchive] = useState(false),
    [selected, setSelected] = useState<string[]>([]);
  const [editor, setEditor] = useState<{ link?: MemberLink; prefill?: MemberLink } | null>(null),
    [qr, setQr] = useState<string | null>(null),
    [policy, setPolicy] = useState<MemberLink | null>(null),
    [analytics, setAnalytics] = useState<string | null>(null),
    [importing, setImporting] = useState(false),
    [access, setAccess] = useState<string | null>(null);
  const [deletingFolder, setDeletingFolder] = useState(false);
  const [bulkFolder, setBulkFolder] = useState('');
  const [folderName, setFolderName] = useState(''),
    [deleting, setDeleting] = useState<string[] | null>(null);
  const filters = { search, isArchived: archive, ...(folder ? { folderId: folder } : {}) };
  const links = useInfiniteQuery({
    queryKey: ['redirect-member', userId, 'links', filters],
    enabled: session.isSuccess,
    initialPageParam: null as string | null,
    queryFn: ({ pageParam, signal }) =>
      memberRedirectApi<{ data: MemberLink[]; count: number; nextCursor: string | null }>(
        '/links?' +
          new URLSearchParams({
            filters: JSON.stringify(filters),
            limit: '50',
            ...(pageParam ? { cursor: pageParam } : {}),
          }),
        'GET',
        undefined,
        signal,
      ),
    getNextPageParam: (page) => page.nextCursor ?? undefined,
    retry: false,
  });
  const rows = links.data?.pages.flatMap((p) => p.data) ?? [];
  const canWrite = session.data?.role === 'member' || session.data?.role === 'owner';
  const refresh = async () => {
    await client.invalidateQueries({ queryKey: ['redirect-member', userId] });
    setSelected([]);
  };
  const mutate = useMutation({
    mutationFn: ({
      path,
      method,
      body,
    }: {
      path: string;
      method: 'POST' | 'PATCH' | 'DELETE';
      body?: Record<string, unknown>;
    }) => memberRedirectApi(path, method, body),
    onSuccess: refresh,
  });
  const bulk = async (action: 'archive' | 'restore' | 'delete', ids = selected) => {
    await mutate.mutateAsync({
      path: '/links/bulk',
      method: 'POST',
      body: {
        operations: ids.map((id) =>
          action === 'delete'
            ? { operation: 'delete', id }
            : { operation: 'update', id, data: { isArchived: action === 'archive' } },
        ),
      },
    });
    setDeleting(null);
  };
  const filterChange = (fn: () => void) => {
    setSelected([]);
    setDeleting(null);
    setDeletingFolder(false);
    setAccess(null);
    fn();
  };
  const selectedRows = rows.filter((r) => selected.includes(r.id));
  const allEditable =
    selected.length > 0 &&
    selectedRows.length === selected.length &&
    selectedRows.every((r) => r.canEdit);
  if (session.isPending) return <p role="status">Checking workspace access…</p>;
  if (session.isError)
    return (
      <section className="space-y-4">
        <h1 className="text-2xl font-semibold">Link workspace access</h1>
        <p role="alert">{session.error.message}</p>
        <p>An administrator can add your existing account to this workspace.</p>
        <Button variant="outline" onClick={() => void session.refetch()}>
          Retry access
        </Button>
      </section>
    );
  return (
    <div className="space-y-6">
      <header className="space-y-4">
        <div>
          <h1 className="text-3xl font-semibold">Link workspace</h1>
          <p className="text-muted-foreground">
            Your shared links, campaign settings, QR codes and analytics.{' '}
            {session.data?.role === 'viewer' ? 'You have read-only workspace access.' : ''}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button disabled={!canWrite || !resources.data} onClick={() => setEditor({})}>
            Create link
          </Button>
          <Button variant="outline" onClick={() => setAnalytics('')}>
            Analytics
          </Button>
          <Button variant="outline" disabled={!canWrite} onClick={() => setImporting(true)}>
            Import CSV
          </Button>
          <Button
            variant="outline"
            disabled={!rows.length}
            onClick={() => exportLinks(selected.length ? selectedRows : rows)}
          >
            {selected.length ? 'Export selected' : 'Export loaded links'}
          </Button>
          <Button variant="ghost" onClick={() => void refresh()}>
            Refresh workspace
          </Button>
        </div>
      </header>
      {resources.isError && (
        <p role="alert">
          {resources.error.message}{' '}
          <Button variant="outline" onClick={() => void resources.refetch()}>
            Retry folders and templates
          </Button>
        </p>
      )}
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="workspace-search">Search links</Label>
          <Input
            id="workspace-search"
            value={search}
            maxLength={200}
            onChange={(e) => filterChange(() => setSearch(e.target.value))}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="workspace-folder">Folder filter</Label>
          <select
            id="workspace-folder"
            className={CONTROL}
            value={folder}
            onChange={(e) => filterChange(() => setFolder(e.target.value))}
          >
            <option value="">All accessible folders</option>
            {resources.data?.folders.map((f) => (
              <option key={f.id} value={f.id}>
                {f.name}
                {f.canEdit ? '' : ' · view only'}
              </option>
            ))}
          </select>
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-4">
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={archive}
            onChange={(e) => filterChange(() => setArchive(e.target.checked))}
          />
          Show archived links
        </label>
        {folder && resources.data?.folders.find((f) => f.id === folder)?.canManage && (
          <Button variant="outline" size="sm" onClick={() => setAccess(folder)}>
            Manage folder access
          </Button>
        )}
      </div>
      {canWrite && (
        <form
          className="flex flex-wrap items-end gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            void mutate
              .mutateAsync({ path: '/folders', method: 'POST', body: { name: folderName } })
              .then(() => setFolderName(''))
              .catch(() => {});
          }}
        >
          <div className="space-y-2">
            <Label htmlFor="new-member-folder">New folder</Label>
            <Input
              id="new-member-folder"
              value={folderName}
              required
              maxLength={100}
              onChange={(e) => setFolderName(e.target.value)}
            />
          </div>
          <Button type="submit" variant="outline" disabled={mutate.isPending || !folderName.trim()}>
            Create folder
          </Button>
        </form>
      )}
      {access && (
        <RedirectFolderAccess
          key={access}
          folderId={access}
          principalId={userId}
          onClose={() => {
            setAccess(null);
            void refresh();
          }}
        />
      )}
      {folder && resources.data?.folders.find((f) => f.id === folder)?.canManage && (
        <section className="space-y-2" aria-label="Folder management">
          <form
            key={folder}
            className="flex flex-wrap items-end gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              const name = String(new FormData(e.currentTarget).get('name') ?? '');
              void mutate
                .mutateAsync({ path: '/folders/' + folder, method: 'PATCH', body: { name } })
                .catch(() => {});
            }}
          >
            <div className="space-y-2">
              <Label htmlFor="rename-member-folder">Folder name</Label>
              <Input
                id="rename-member-folder"
                name="name"
                defaultValue={resources.data.folders.find((f) => f.id === folder)?.name}
                maxLength={100}
                required
              />
            </div>
            <Button type="submit" variant="outline" disabled={mutate.isPending}>
              Rename folder
            </Button>
            <Button type="button" variant="ghost" onClick={() => setDeletingFolder(true)}>
              Delete folder
            </Button>
          </form>
          {deletingFolder && (
            <div className="space-y-2">
              <p>
                {session.data?.role === 'owner'
                  ? 'Delete this folder and move its links to Unfiled?'
                  : 'Delete this folder? Move all its links out first.'}
              </p>
              <Button
                variant="destructive"
                disabled={mutate.isPending}
                onClick={() =>
                  void mutate
                    .mutateAsync({ path: '/folders/' + folder, method: 'DELETE' })
                    .then(() => {
                      setFolder('');
                      setDeletingFolder(false);
                    })
                    .catch(() => {})
                }
              >
                Confirm folder deletion
              </Button>
              <Button variant="ghost" onClick={() => setDeletingFolder(false)}>
                Cancel folder deletion
              </Button>
            </div>
          )}
        </section>
      )}
      {mutate.isError && (
        <p role="alert" className="text-destructive">
          {mutate.error.message}
        </p>
      )}
      {selected.length > 0 && (
        <section
          aria-label="Selected links"
          className="flex flex-wrap items-center gap-2 border-y py-4"
        >
          <span>{selected.length} selected</span>
          <Label htmlFor="selected-folder">Move selected links</Label>
          <select
            id="selected-folder"
            className="rounded-element border bg-background p-2 text-sm"
            value={bulkFolder}
            onChange={(e) => setBulkFolder(e.target.value)}
          >
            <option value="">Unfiled</option>
            {resources.data?.folders
              .filter((f) => f.canEdit)
              .map((f) => (
                <option key={f.id} value={f.id}>
                  {f.name}
                </option>
              ))}
          </select>
          <Button
            size="sm"
            variant="outline"
            disabled={!allEditable || mutate.isPending}
            onClick={() =>
              void mutate
                .mutateAsync({
                  path: '/links/bulk',
                  method: 'POST',
                  body: {
                    operations: selected.map((id) => ({
                      operation: 'update',
                      id,
                      data: { folderId: bulkFolder || null },
                    })),
                  },
                })
                .catch(() => {})
            }
          >
            Move selected
          </Button>

          <Button
            size="sm"
            variant="outline"
            disabled={!allEditable || mutate.isPending}
            onClick={() => void bulk(archive ? 'restore' : 'archive').catch(() => {})}
          >
            {archive ? 'Restore selected' : 'Archive selected'}
          </Button>
          <Button
            size="sm"
            variant="destructive"
            disabled={!allEditable || mutate.isPending}
            onClick={() => setDeleting([...selected])}
          >
            Delete selected
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setSelected([])}>
            Clear selection
          </Button>
        </section>
      )}
      {deleting && (
        <section aria-label="Confirm deletion" className="space-y-2 rounded-container border p-4">
          <p>Permanently delete {deleting.length} link(s) and their tracking history?</p>
          <div className="flex gap-2">
            <Button
              variant="destructive"
              disabled={mutate.isPending}
              onClick={() => void bulk('delete', deleting).catch(() => {})}
            >
              Confirm permanent deletion
            </Button>
            <Button variant="outline" disabled={mutate.isPending} onClick={() => setDeleting(null)}>
              Cancel deletion
            </Button>
          </div>
        </section>
      )}
      {links.isPending && <p role="status">Loading links…</p>}
      {links.isError && (
        <p role="alert">
          {links.error.message}{' '}
          <Button variant="outline" onClick={() => void links.refetch()}>
            Retry links
          </Button>
        </p>
      )}
      {links.data && (
        <p className="text-sm text-muted-foreground">
          {rows.length} loaded of {links.data.pages[0].count} accessible links
        </p>
      )}
      <ul className="divide-y">
        {rows.map((link) => (
          <li key={link.id} className="space-y-4 py-4">
            <div className="flex items-start gap-4">
              <input
                type="checkbox"
                aria-label={'Select /go/' + link.slug}
                className="mt-2"
                checked={selected.includes(link.id)}
                disabled={!selected.includes(link.id) && selected.length >= 100}
                onChange={(e) =>
                  setSelected(
                    e.target.checked
                      ? [...selected, link.id]
                      : selected.filter((id) => id !== link.id),
                  )
                }
              />
              <div className="min-w-0 flex-1">
                <a
                  className="break-all font-semibold underline"
                  href={link.shortUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  /go/{link.slug}
                </a>
                <p className="break-all text-sm">{link.target}</p>
                <p className="text-xs text-muted-foreground">
                  {link.clicks} clicks · {link.canEdit ? 'Can edit' : 'View only'} ·{' '}
                  {inventory(link).state}
                  {link.isArchived ? ' · Archived' : ''}
                </p>
                {link.comment && (
                  <p className="whitespace-pre-wrap break-words text-sm">{link.comment}</p>
                )}
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={!link.canEdit || !resources.data}
                onClick={() => setEditor({ link })}
              >
                Edit /go/{link.slug}
              </Button>
              <Button size="sm" variant="outline" onClick={() => setPolicy(link)}>
                Link behavior
              </Button>
              <Button size="sm" variant="outline" onClick={() => setQr(link.shortUrl)}>
                QR code
              </Button>
              <Button size="sm" variant="outline" onClick={() => setAnalytics(link.id)}>
                Link analytics
              </Button>
              <Button
                size="sm"
                variant="ghost"
                disabled={!canWrite || !resources.data}
                onClick={() => setEditor({ prefill: link })}
              >
                Create from link
              </Button>
              <Button
                size="sm"
                variant="ghost"
                disabled={!link.canEdit || mutate.isPending}
                onClick={() =>
                  void mutate
                    .mutateAsync({
                      path: '/links/' + link.id,
                      method: 'PATCH',
                      body: { isArchived: !link.isArchived },
                    })
                    .catch(() => {})
                }
              >
                {link.isArchived ? 'Restore' : 'Archive'}
              </Button>
            </div>
          </li>
        ))}
      </ul>
      {links.isSuccess && !rows.length && <p>No accessible links match these filters.</p>}
      {links.hasNextPage && (
        <Button
          variant="outline"
          disabled={links.isFetchingNextPage}
          onClick={() => void links.fetchNextPage()}
        >
          {links.isFetchingNextPage ? 'Loading…' : 'Load more links'}
        </Button>
      )}
      {editor && resources.data && (
        <LinkEditor
          key={editor.link?.id ?? editor.prefill?.id ?? 'new'}
          {...editor}
          resources={resources.data}
          onClose={() => setEditor(null)}
          onSave={async (body) => {
            const result = await mutate.mutateAsync({
              path: '/links' + (editor.link ? '/' + editor.link.id : ''),
              method: editor.link ? 'PATCH' : 'POST',
              body,
            });
            return result;
          }}
        />
      )}
      {qr && <RedirectQrDialog url={qr} onClose={() => setQr(null)} />}{' '}
      {policy && (
        <RedirectPolicyDialog
          row={inventory(policy)}
          principalId={userId}
          readOnly={!policy.canEdit}
          onClose={() => setPolicy(null)}
        />
      )}
      {analytics !== null && (
        <MemberRedirectAnalyticsDialog
          links={rows.map(inventory)}
          initialLink={analytics || undefined}
          initialFolder={analytics ? undefined : folder || undefined}
          principalId={userId}
          onClose={() => setAnalytics(null)}
        />
      )}
      {importing && <RedirectManagedImportDialog onClose={() => setImporting(false)} />}
    </div>
  );
}
export default function RedirectMemberWorkspace() {
  const { user, loading } = useAuth();
  const location = useLocation();
  if (loading) return <p role="status">Loading account…</p>;
  if (!user || user.is_anonymous)
    return (
      <Navigate
        to={'/auth?redirect=' + encodeURIComponent(location.pathname + location.search)}
        replace
      />
    );
  return (
    <PageContainer>
      <MemberWorkspaceContent key={user.id} userId={user.id} />
    </PageContainer>
  );
}
