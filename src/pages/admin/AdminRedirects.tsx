import { useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { Download, Plus, RefreshCw } from 'lucide-react';
import { AdminArchetypeHeader } from '@/components/admin/frames/AdminArchetypeHeader';
import { useAdminShell } from '@/components/admin/shell/AdminShell';
import { RedirectToolbarActions } from '@/components/admin/redirects/RedirectToolbarActions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { useRedirectInventory } from '@/hooks/useRedirectInventory';
import { filterInventory, type InventoryRedirect } from '@/lib/redirects/inventory';
import { publicSourceUrl } from '@/lib/redirects/linkTools';
import { RedirectLinkBuilder } from '@/components/admin/redirects/RedirectLinkBuilder';
import { RedirectQrDialog } from '@/components/admin/redirects/RedirectQrDialog';
import { RedirectTrackingDialog } from '@/components/admin/redirects/RedirectTrackingDialog';
import { RedirectWorkspaceDialog } from '@/components/admin/redirects/RedirectWorkspaceDialog';
import { RedirectOrganizationDialog } from '@/components/admin/redirects/RedirectOrganizationDialog';
import { RedirectPolicyDialog } from '@/components/admin/redirects/RedirectPolicyDialog';
import { useRedirectWorkspace } from '@/hooks/useRedirectWorkspace';
import { commentSegments, filterWorkspaceLinks } from '@/lib/redirects/workspace';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';

const PAGE_SIZE = 50;
const SELECT_CLASS =
  'h-9 max-w-full rounded-element border border-input bg-background px-4 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring';

function exportRows(rows: InventoryRedirect[]) {
  const quote = (value: unknown) => `"${String(value ?? '').replace(/"/g, '""')}"`;
  const lines = [
    ['Source', 'Destination', 'HTTP status', 'State', 'Origin', 'Kind'],
    ...rows.map((row) => [row.source, row.target, row.statusCode, row.state, row.origin, row.kind]),
  ];
  const url = URL.createObjectURL(
    new Blob([lines.map((line) => line.map(quote).join(',')).join('\r\n')], {
      type: 'text/csv;charset=utf-8',
    }),
  );
  const link = document.createElement('a');
  link.href = url;
  link.download = 'queerguide-redirects.csv';
  link.click();
  URL.revokeObjectURL(url);
}

export default function AdminRedirects() {
  const inventory = useRedirectInventory();
  const workspace = useRedirectWorkspace();
  const { openEditor } = useAdminShell();
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState('');
  const [origin, setOrigin] = useState('');
  const [state, setState] = useState('');
  const [sort, setSort] = useState('updated');
  const [page, setPage] = useState(0);
  const [linkSeed, setLinkSeed] = useState<{ row: InventoryRedirect | null } | null>(null);
  const [qrUrl, setQrUrl] = useState<string | null>(null);
  const [tracking, setTracking] = useState<InventoryRedirect | null>(null);
  const [workspaceOpen, setWorkspaceOpen] = useState(false);
  const [organization, setOrganization] = useState<InventoryRedirect | null>(null);
  const [policyLink, setPolicyLink] = useState<InventoryRedirect | null>(null);
  const folderFilter = searchParams.get('folder') ?? '';
  const tagFilter = searchParams.get('tag') ?? '';

  useEffect(() => {
    const id = searchParams.get('edit');
    if (!id) return;
    openEditor('redirects', id);
    setSearchParams(
      (params) => {
        params.delete('edit');
        return params;
      },
      { replace: true },
    );
  }, [searchParams, setSearchParams, openEditor]);

  const rows = inventory.data?.rows;
  const origins = useMemo(() => [...new Set(rows?.map((row) => row.origin) ?? [])].sort(), [rows]);
  const baseFiltered = useMemo(
    () =>
      filterInventory(rows ?? [], search, origin, state).sort((a, b) =>
        sort === 'source'
          ? a.source.localeCompare(b.source) || a.id.localeCompare(b.id)
          : (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '') ||
            a.source.localeCompare(b.source) ||
            a.id.localeCompare(b.id),
      ),
    [rows, search, origin, state, sort],
  );
  const filtered = useMemo(
    () =>
      workspace.data
        ? filterWorkspaceLinks(baseFiltered, workspace.data.metadata, folderFilter, tagFilter)
        : baseFiltered,
    [baseFiltered, workspace.data, folderFilter, tagFilter],
  );
  const setOrganizationFilter = (key: 'folder' | 'tag', value: string) => {
    setPage(0);
    setSearchParams(
      (params) => {
        if (value) params.set(key, value);
        else params.delete(key);
        return params;
      },
      { replace: true },
    );
  };
  const lastPage = Math.max(0, Math.ceil(filtered.length / PAGE_SIZE) - 1);
  const currentPage = Math.min(page, lastPage);
  const visible = filtered.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE);
  const partial = !!inventory.data?.errors.length;

  return (
    <div className="min-w-0">
      <AdminArchetypeHeader
        title={
          <>
            Redirects{' '}
            <span className="text-muted-foreground tabular-nums">
              {rows ? `${partial ? '≥ ' : ''}${rows.length.toLocaleString()}` : '…'}
            </span>
          </>
        }
        actions={
          <>
            <Button
              variant="outline"
              size="sm"
              onClick={() => void inventory.refetch()}
              disabled={inventory.isFetching}
            >
              <RefreshCw size={14} aria-hidden className="mr-1" />
              Refresh
            </Button>
            <RedirectToolbarActions />
            <Button variant="outline" size="sm" onClick={() => setWorkspaceOpen(true)}>
              Folders, tags &amp; templates
            </Button>
            <Button variant="outline" size="sm" onClick={() => setLinkSeed({ row: null })}>
              Create tracked link
            </Button>
            <Button size="sm" onClick={() => openEditor('redirects', null)}>
              <Plus size={14} aria-hidden className="mr-1" />
              New Redirect
            </Button>
          </>
        }
      />
      <p className="mb-4 text-13 text-muted-foreground">
        Manual links, automatic aliases, static rules, and client route redirects. Automatic and
        static rules are managed at their source.{' '}
        <Link to="/admin/content/redirects/manual" className="underline underline-offset-2">
          Manage manual rules
        </Link>
        .
      </p>
      <div
        className="mb-4 flex flex-wrap items-center gap-2"
        role="search"
        aria-label="Search redirects"
      >
        <Input
          className="min-w-0 flex-1 basis-64"
          aria-label="Search redirects"
          placeholder="Search source, destination, or origin"
          value={search}
          onChange={(event) => {
            setSearch(event.target.value);
            setPage(0);
          }}
        />
        <select
          className={SELECT_CLASS}
          aria-label="Redirect origin"
          value={origin}
          onChange={(event) => {
            setOrigin(event.target.value);
            setPage(0);
          }}
        >
          <option value="">All origins</option>
          {origins.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </select>
        <select
          className={SELECT_CLASS}
          aria-label="Redirect state"
          value={state}
          onChange={(event) => {
            setState(event.target.value);
            setPage(0);
          }}
        >
          <option value="">All states</option>
          {[
            'Enabled',
            'Disabled',
            'Scheduled',
            'Expired',
            'Limit reached',
            'Missing target',
            'Recorded',
          ].map((value) => (
            <option key={value}>{value}</option>
          ))}
        </select>
        <select
          className={SELECT_CLASS}
          aria-label="Sort redirects"
          value={sort}
          onChange={(event) => {
            setSort(event.target.value);
            setPage(0);
          }}
        >
          <option value="updated">Newest first</option>
          <option value="source">Source A–Z</option>
        </select>
        <Button
          variant="outline"
          size="sm"
          disabled={!filtered.length}
          onClick={() => exportRows(filtered)}
        >
          <Download size={14} aria-hidden className="mr-1" />
          Export
        </Button>
        <select
          className={SELECT_CLASS}
          aria-label="Filter by folder"
          value={folderFilter}
          disabled={!workspace.data}
          onChange={(event) => setOrganizationFilter('folder', event.target.value)}
        >
          <option value="">All folders</option>
          <option value="unfiled">Unfiled</option>
          {workspace.data?.folders.map((folder) => (
            <option value={folder.id} key={folder.id}>
              {folder.name}
            </option>
          ))}
        </select>
        <select
          className={SELECT_CLASS}
          aria-label="Filter by tag"
          value={tagFilter}
          disabled={!workspace.data}
          onChange={(event) => setOrganizationFilter('tag', event.target.value)}
        >
          <option value="">All tags</option>
          {workspace.data?.tags.map((tag) => (
            <option value={tag.id} key={tag.id}>
              {tag.name}
            </option>
          ))}
        </select>
        {(folderFilter || tagFilter) && (
          <Button
            variant="outline"
            size="sm"
            onClick={() => void navigator.clipboard.writeText(window.location.href)}
          >
            Copy filtered view
          </Button>
        )}
      </div>
      {workspace.isError && (
        <div role="alert" className="mb-4 text-sm text-destructive">
          Could not load folders, tags, and templates. Organization filters are unavailable.{' '}
          <Button variant="outline" size="sm" onClick={() => void workspace.refetch()}>
            Retry workspace
          </Button>
        </div>
      )}
      {partial && (
        <div role="alert" className="mb-4 rounded-element border border-destructive p-4 text-13">
          <p className="font-medium">
            Some redirect sources could not be loaded. This list and its total are incomplete.
          </p>
          <ul className="mt-2 list-disc pl-4">
            {inventory.data!.errors.map((error) => (
              <li key={error}>{error}</li>
            ))}
          </ul>
          <Button
            variant="outline"
            size="sm"
            className="mt-2"
            onClick={() => void inventory.refetch()}
            disabled={inventory.isFetching}
          >
            Retry failed sources
          </Button>
        </div>
      )}
      {inventory.isError && (
        <p role="alert" className="mb-4 text-destructive">
          Could not load redirects. {inventory.error.message}
        </p>
      )}
      {inventory.isPending ? (
        <p role="status" className="py-8 text-muted-foreground">
          Loading all redirect sources…
        </p>
      ) : (
        <>
          <Table variant="admin" aria-label="Redirects">
            <TableHeader>
              <TableRow>
                <TableHead>Source</TableHead>
                <TableHead>Destination</TableHead>
                <TableHead>HTTP</TableHead>
                <TableHead>State</TableHead>
                <TableHead>Origin</TableHead>
                <TableHead>Organization</TableHead>
                <TableHead>Visits</TableHead>
                <TableHead>Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {visible.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="min-w-48 max-w-80 break-words font-mono text-xs">
                    {row.source}
                  </TableCell>
                  <TableCell className="min-w-48 max-w-80 break-words font-mono text-xs">
                    {row.target ?? (
                      <span className="font-sans text-muted-foreground">
                        Destination unavailable
                      </span>
                    )}
                  </TableCell>
                  <TableCell className="tabular-nums">
                    {row.statusCode ?? (row.kind === 'Client' ? 'Client' : '—')}
                  </TableCell>
                  <TableCell className="whitespace-nowrap">{row.state}</TableCell>
                  <TableCell>
                    <span className="block whitespace-nowrap">{row.kind}</span>
                    <span className="text-xs text-muted-foreground">{row.origin}</span>
                  </TableCell>
                  <TableCell className="min-w-40 max-w-64">
                    <p className="text-xs text-muted-foreground">
                      {workspace.data?.folders.find(
                        (folder) => folder.id === workspace.data?.metadata.get(row.id)?.folder_id,
                      )?.name ?? 'Unfiled'}
                    </p>
                    <div className="mt-1 flex flex-wrap gap-1">
                      {workspace.data?.tags
                        .filter((tag) =>
                          workspace.data?.metadata.get(row.id)?.tagIds.includes(tag.id),
                        )
                        .map((tag) => (
                          <span
                            key={tag.id}
                            className="rounded-badge bg-muted px-2 py-0.5 text-xs"
                            title={`Tag color: ${tag.color}`}
                          >
                            <span
                              aria-hidden
                              className="redirect-tag-swatch mr-1 inline-block h-2 w-2 rounded-badge"
                              data-color={tag.color}
                            />
                            {tag.name}
                          </span>
                        ))}
                    </div>
                    {workspace.data?.metadata.get(row.id)?.comment && (
                      <p className="mt-1 whitespace-pre-wrap break-words text-xs">
                        {commentSegments(workspace.data.metadata.get(row.id)!.comment).map(
                          (segment, index) =>
                            segment.url ? (
                              <a
                                className="underline underline-offset-2"
                                href={segment.url}
                                target="_blank"
                                rel="noopener noreferrer"
                                key={index}
                              >
                                {segment.text}
                              </a>
                            ) : (
                              <span key={index}>{segment.text}</span>
                            ),
                        )}
                      </p>
                    )}
                  </TableCell>
                  <TableCell className="tabular-nums">
                    {row.manualId ? (
                      (row.clicks ?? 0).toLocaleString()
                    ) : (
                      <span className="text-xs text-muted-foreground">Not tracked</span>
                    )}
                  </TableCell>
                  <TableCell>
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button variant="ghost" size="sm">
                          Tools
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        {row.manualId && row.source.startsWith('/go/') && (
                          <DropdownMenuItem onSelect={() => setPolicyLink(row)}>
                            Targeting, A/B &amp; access
                          </DropdownMenuItem>
                        )}
                        <DropdownMenuItem
                          disabled={!workspace.data}
                          onSelect={() => setOrganization(row)}
                        >
                          Folder, tags &amp; comment
                        </DropdownMenuItem>
                        <DropdownMenuItem onSelect={() => setLinkSeed({ row })}>
                          Create tracked link
                        </DropdownMenuItem>
                        <DropdownMenuItem
                          disabled={!publicSourceUrl(row.source)}
                          onSelect={() => setQrUrl(publicSourceUrl(row.source))}
                        >
                          QR code
                        </DropdownMenuItem>
                        {row.manualId ? (
                          <>
                            <DropdownMenuItem onSelect={() => setTracking(row)}>
                              Visit tracking
                            </DropdownMenuItem>
                            <DropdownMenuItem
                              onSelect={() => openEditor('redirects', row.manualId!)}
                            >
                              Edit redirect
                            </DropdownMenuItem>
                          </>
                        ) : (
                          <DropdownMenuItem disabled>Managed at source</DropdownMenuItem>
                        )}
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </TableCell>
                </TableRow>
              ))}
              {!visible.length && (
                <TableRow>
                  <TableCell colSpan={8} className="py-12 text-center text-muted-foreground">
                    {rows?.length
                      ? 'No redirects match these filters.'
                      : partial
                        ? 'No records loaded. Retry the failed sources above.'
                        : 'No redirects found.'}
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
          <div className="mt-4 flex flex-wrap items-center justify-between gap-2">
            <p
              role="status"
              aria-live="polite"
              className="text-13 text-muted-foreground tabular-nums"
            >
              {filtered.length ? currentPage * PAGE_SIZE + 1 : 0}–
              {Math.min((currentPage + 1) * PAGE_SIZE, filtered.length)} of{' '}
              {filtered.length.toLocaleString()}
              {partial ? ' loaded redirects' : ' redirects'}
              {inventory.isFetching ? ' · Refreshing…' : ''}
            </p>
            <nav aria-label="Redirect pages" className="flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                disabled={currentPage === 0}
                onClick={() => setPage(currentPage - 1)}
              >
                Previous
              </Button>
              <span className="text-13 tabular-nums">
                {currentPage + 1} / {lastPage + 1}
              </span>
              <Button
                variant="outline"
                size="sm"
                disabled={currentPage >= lastPage}
                onClick={() => setPage(currentPage + 1)}
              >
                Next
              </Button>
            </nav>
          </div>
        </>
      )}
      {linkSeed && (
        <RedirectLinkBuilder
          seed={linkSeed.row}
          defaultFolderId={folderFilter === 'unfiled' ? '' : folderFilter}
          onClose={() => setLinkSeed(null)}
        />
      )}
      {qrUrl && <RedirectQrDialog url={qrUrl} onClose={() => setQrUrl(null)} />}
      {tracking && <RedirectTrackingDialog row={tracking} onClose={() => setTracking(null)} />}
      {workspaceOpen && <RedirectWorkspaceDialog onClose={() => setWorkspaceOpen(false)} />}
      {policyLink && <RedirectPolicyDialog row={policyLink} onClose={() => setPolicyLink(null)} />}
      {organization && (
        <RedirectOrganizationDialog
          key={organization.id}
          row={organization}
          onClose={() => setOrganization(null)}
        />
      )}
    </div>
  );
}
