import { useState } from 'react';
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '@/hooks/useAuth';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import type { AnalyticsFilters } from '@/lib/redirects/analytics';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
interface SavedReport {
  id: string;
  name: string;
  filters: AnalyticsFilters;
  version: string;
  updated_at: string;
}
interface Share {
  id: string;
  title: string;
  scopeMode: string;
  linkCount: number;
  includeConversions: boolean;
  hasPassword: boolean;
  allowIndexing: boolean;
  expiresAt: string | null;
  revokedAt?: string | null;
}
const shareUrl = (id: string) => 'https://queer.guide/share/redirect-report/' + id;
export function RedirectSavedReports({
  filters,
  onLoad,
  principalId,
}: {
  filters: AnalyticsFilters;
  onLoad: (filters: AnalyticsFilters) => void;
  principalId?: string;
}) {
  return principalId ? (
    <SavedReports key={principalId} userId={principalId} filters={filters} onLoad={onLoad} />
  ) : (
    <AccountReports filters={filters} onLoad={onLoad} />
  );
}
function AccountReports(props: {
  filters: AnalyticsFilters;
  onLoad: (filters: AnalyticsFilters) => void;
}) {
  const { user } = useAuth();
  return user ? <SavedReports key={user.id} userId={user.id} {...props} /> : null;
}
function SavedReports({
  userId,
  filters,
  onLoad,
}: {
  userId: string;
  filters: AnalyticsFilters;
  onLoad: (filters: AnalyticsFilters) => void;
}) {
  const client = useQueryClient();
  const [name, setName] = useState(''),
    [active, setActive] = useState<SavedReport | null>(null),
    [remove, setRemove] = useState(false),
    [sharing, setSharing] = useState(false);
  const query = useInfiniteQuery({
    queryKey: ['redirect-saved-reports', userId],
    initialPageParam: null as string | null,
    queryFn: ({ pageParam, signal }) =>
      memberRedirectApi<{ data: SavedReport[]; count: number; nextCursor: string | null }>(
        '/reports?' +
          new URLSearchParams({ limit: '50', ...(pageParam ? { cursor: pageParam } : {}) }),
        'GET',
        undefined,
        signal,
      ),
    getNextPageParam: (page) => page.nextCursor ?? undefined,
    retry: false,
  });
  const mutation = useMutation({
    mutationFn: ({
      method,
      id,
      body,
    }: {
      method: 'POST' | 'PATCH' | 'DELETE';
      id?: string;
      body?: Record<string, unknown>;
    }) => memberRedirectApi<SavedReport>('/reports' + (id ? '/' + id : ''), method, body),
    onSuccess: async (data, variables) => {
      setActive(variables.method === 'DELETE' ? null : data);
      if (variables.method === 'DELETE') {
        setName('');
        setRemove(false);
        setSharing(false);
      }
      await client.invalidateQueries({ queryKey: ['redirect-saved-reports', userId] });
    },
  });
  return (
    <details className="space-y-4 rounded-container border p-4">
      <summary className="cursor-pointer font-medium">Saved reports and sharing</summary>
      <p className="text-sm text-muted-foreground">
        Save the applied filters and dates. Reports are private to your account until you explicitly
        publish a dashboard.
      </p>
      <div className="space-y-2">
        <Label htmlFor="saved-report-name">Report name</Label>
        <Input
          id="saved-report-name"
          maxLength={100}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </div>
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          disabled={!name.trim() || mutation.isPending}
          onClick={() => mutation.mutate({ method: 'POST', body: { name, filters } })}
        >
          Save as new report
        </Button>
        {active && (
          <>
            <Button
              type="button"
              variant="outline"
              disabled={!name.trim() || mutation.isPending}
              onClick={() =>
                mutation.mutate({
                  method: 'PATCH',
                  id: active.id,
                  body: { name, filters, version: active.version },
                })
              }
            >
              Update selected report
            </Button>
            <Button type="button" variant="outline" onClick={() => setSharing(!sharing)}>
              {sharing ? 'Hide sharing' : 'Share selected report'}
            </Button>
            <Button type="button" variant="ghost" onClick={() => setRemove(true)}>
              Delete selected report
            </Button>
          </>
        )}
      </div>
      {remove && active && (
        <div className="space-y-2">
          <p>Delete “{active.name}” and revoke every public dashboard created from it?</p>
          <Button
            type="button"
            variant="destructive"
            disabled={mutation.isPending}
            onClick={() => mutation.mutate({ method: 'DELETE', id: active.id })}
          >
            Confirm report deletion
          </Button>
          <Button type="button" variant="ghost" onClick={() => setRemove(false)}>
            Keep report
          </Button>
        </div>
      )}
      {mutation.isError && (
        <p role="alert" className="text-destructive">
          {mutation.error.message}
        </p>
      )}
      {query.isError && (
        <p role="alert">
          {query.error.message}{' '}
          <Button type="button" variant="outline" onClick={() => void query.refetch()}>
            Retry saved reports
          </Button>
        </p>
      )}
      {query.isPending && <p role="status">Loading saved reports…</p>}
      <ul className="space-y-2">
        {query.data?.pages
          .flatMap((p) => p.data)
          .map((report) => (
            <li
              key={report.id}
              className="flex flex-wrap items-center justify-between gap-2 border-t pt-2"
            >
              <span>
                {report.name}
                {active?.id === report.id ? ' · Selected' : ''}
              </span>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => {
                  setActive(report);
                  setName(report.name);
                  setRemove(false);
                  setSharing(false);
                  onLoad(report.filters);
                }}
              >
                Load report
              </Button>
            </li>
          ))}
      </ul>
      {query.hasNextPage && (
        <Button
          type="button"
          variant="outline"
          disabled={query.isFetchingNextPage}
          onClick={() => void query.fetchNextPage()}
        >
          Load more reports
        </Button>
      )}
      {sharing && active && (
        <ReportSharing key={active.id + active.version} report={active} userId={userId} />
      )}
    </details>
  );
}
function ReportSharing({ report, userId }: { report: SavedReport; userId: string }) {
  const client = useQueryClient();
  const [openedAt] = useState(() => Date.now());
  const [title, setTitle] = useState(report.name),
    [conversions, setConversions] = useState(false),
    [password, setPassword] = useState(''),
    [allowIndexing, setAllowIndexing] = useState(false),
    [days, setDays] = useState('30'),
    [mode, setMode] = useState('snapshot'),
    [review, setReview] = useState(false),
    [message, setMessage] = useState(''),
    [revoking, setRevoking] = useState<string | null>(null);
  const query = useQuery({
    queryKey: ['redirect-report-shares', userId, report.id],
    queryFn: () => memberRedirectApi<{ data: Share[] }>('/reports/' + report.id + '/shares'),
    retry: false,
  });
  const change = useMutation({
    mutationFn: ({ id, body }: { id?: string; body?: Record<string, unknown> }) =>
      memberRedirectApi<Share>(
        '/reports/' + report.id + '/shares' + (id ? '/' + id : ''),
        id ? 'DELETE' : 'POST',
        body,
      ),
    onSuccess: async () => {
      setReview(false);
      setRevoking(null);
      setPassword('');
      await client.invalidateQueries({ queryKey: ['redirect-report-shares', userId, report.id] });
    },
  });
  const copy = async (id: string) => {
    try {
      await navigator.clipboard.writeText(shareUrl(id));
      setMessage('Dashboard link copied.');
    } catch {
      setMessage('Could not copy. Select and copy the dashboard URL below.');
    }
  };
  return (
    <section aria-label="Report sharing" className="space-y-4 border-t pt-4">
      <h3 className="font-medium">Publish an aggregate dashboard</h3>
      <p className="text-sm">
        Public dashboards expose counts, broad device/country breakdowns and the title below. Raw
        events, customer IDs, destinations and comments stay private. Folder and multi-link
        publishing requires a workspace owner.
      </p>
      <div className="space-y-2">
        <Label htmlFor="report-public-title">Public dashboard title</Label>
        <Input
          id="report-public-title"
          value={title}
          maxLength={100}
          disabled={review || change.isPending}
          onChange={(e) => setTitle(e.target.value)}
        />
      </div>
      <p className="text-sm">
        Saved dates:{' '}
        {report.filters.start
          ? new Date(report.filters.start).toISOString().replace('T', ' ').slice(0, 16) + ' UTC'
          : 'first recorded event'}{' '}
        to{' '}
        {report.filters.end
          ? 'before ' +
            new Date(report.filters.end).toISOString().replace('T', ' ').slice(0, 16) +
            ' UTC'
          : 'now'}
        . Scope:{' '}
        {report.filters.folderId
          ? 'matching folder'
          : report.filters.linkIds
            ? report.filters.linkIds.length + ' selected link(s)'
            : 'all accessible managed links'}
        {report.filters.tagId ? ' with a tag filter' : ''}.
      </p>
      <p className="text-sm text-muted-foreground">
        Applied filters:{' '}
        {Object.entries(report.filters)
          .filter(([key]) => !['linkIds', 'folderId', 'tagId', 'start', 'end'].includes(key))
          .map(([key, value]) => key + ': ' + String(value))
          .join(' · ') || 'none'}
        .
      </p>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={conversions}
          disabled={review || change.isPending}
          onChange={(e) => setConversions(e.target.checked)}
        />
        Include aggregate leads, sales, customer count and revenue
      </label>
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="report-share-password">Dashboard password (optional)</Label>
          <Input
            id="report-share-password"
            type="password"
            autoComplete="new-password"
            maxLength={256}
            value={password}
            disabled={review || change.isPending}
            onChange={(e) => {
              setPassword(e.target.value);
              if (e.target.value) setAllowIndexing(false);
            }}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="report-share-expiry">Expires after</Label>
          <select
            id="report-share-expiry"
            className="w-full rounded-element border bg-background p-2"
            value={days}
            disabled={review || change.isPending}
            onChange={(e) => setDays(e.target.value)}
          >
            <option value="7">7 days</option>
            <option value="30">30 days</option>
            <option value="90">90 days</option>
            <option value="365">1 year</option>
            <option value="never">Never (until revoked)</option>
          </select>
        </div>
      </div>
      <div className="space-y-2">
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={allowIndexing}
            disabled={!!password || review || change.isPending}
            onChange={(event) => setAllowIndexing(event.target.checked)}
          />
          Allow search engines to index this dashboard
        </label>
        <p className="text-sm text-muted-foreground">
          Off by default. Indexing can make the dashboard title and published aggregates
          discoverable in search results. Password-protected dashboards cannot be indexed. Search
          engines may retain copies after revocation.
        </p>
      </div>
      {report.filters.folderId && !report.filters.linkIds && (
        <div className="space-y-2">
          <Label htmlFor="report-share-mode">Folder scope</Label>
          <select
            id="report-share-mode"
            className="w-full rounded-element border bg-background p-2"
            value={mode}
            disabled={review || change.isPending}
            onChange={(e) => setMode(e.target.value)}
          >
            <option value="snapshot">Only links currently in this report</option>
            <option value="folder">Include future links matching this folder report</option>
          </select>
        </div>
      )}
      {!review ? (
        <Button
          type="button"
          variant="outline"
          disabled={!title.trim()}
          onClick={() => setReview(true)}
        >
          Review public sharing
        </Button>
      ) : (
        <div className="space-y-2 rounded-container border p-4">
          <p>
            Publish “{title}” with{' '}
            {conversions ? 'clicks and conversion totals' : 'click totals only'},{' '}
            {password ? 'password protection' : 'access for anyone with the link'},{' '}
            {mode === 'folder'
              ? 'including future matching folder links'
              : 'limited to the currently matching link set'}
            , {allowIndexing ? 'search indexing enabled' : 'search indexing disabled'}, expiring{' '}
            {days === 'never' ? 'only when revoked' : 'after ' + days + ' days'}?
          </p>
          <p className="text-sm">
            Saved filters and dates are copied into this share. Editing the private report later
            will not expand an existing dashboard.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              disabled={change.isPending}
              onClick={() =>
                change.mutate({
                  body: {
                    title,
                    reportVersion: report.version,
                    includeConversions: conversions,
                    allowIndexing,
                    scopeMode: mode,
                    expiresAt:
                      days === 'never'
                        ? null
                        : new Date(Date.now() + Number(days) * 86400000).toISOString(),
                    ...(password ? { password } : {}),
                  },
                })
              }
            >
              {change.isPending ? 'Publishing…' : 'Confirm public sharing'}
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={change.isPending}
              onClick={() => setReview(false)}
            >
              Change share settings
            </Button>
          </div>
        </div>
      )}
      {change.isError && (
        <p role="alert" className="text-destructive">
          {change.error.message}
        </p>
      )}
      {message && <p role="status">{message}</p>}
      {query.isError && <p role="alert">{query.error.message}</p>}
      <ul className="space-y-4">
        {query.data?.data.map((share) => (
          <li key={share.id} className="space-y-2 border-t pt-4">
            <p className="font-medium">
              {share.title} ·{' '}
              {share.revokedAt
                ? 'Revoked'
                : share.expiresAt && Date.parse(share.expiresAt) <= openedAt
                  ? 'Expired'
                  : 'Active'}
            </p>
            <p className="text-xs text-muted-foreground">
              {share.linkCount} links at publication ·{' '}
              {share.includeConversions ? 'Conversions included' : 'Clicks only'} ·{' '}
              {share.hasPassword ? 'Password protected' : 'Anyone with link'} ·{' '}
              {share.allowIndexing ? 'Search indexing enabled' : 'Search indexing disabled'}
            </p>
            <Input
              aria-label={'Dashboard URL for ' + share.title}
              value={shareUrl(share.id)}
              readOnly
            />
            {!share.revokedAt && (
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => void copy(share.id)}
                >
                  Copy dashboard link
                </Button>
                {revoking === share.id ? (
                  <>
                    <Button
                      type="button"
                      size="sm"
                      variant="destructive"
                      disabled={change.isPending}
                      onClick={() => change.mutate({ id: share.id })}
                    >
                      Confirm revocation
                    </Button>
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      onClick={() => setRevoking(null)}
                    >
                      Keep sharing
                    </Button>
                  </>
                ) : (
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    onClick={() => setRevoking(share.id)}
                  >
                    Revoke dashboard
                  </Button>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
