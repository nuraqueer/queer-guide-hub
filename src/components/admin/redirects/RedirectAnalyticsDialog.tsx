import { RedirectCustomerDetails } from './RedirectCustomerDetails';
import { RedirectSavedReports } from './RedirectSavedReports';
import { useMemberRedirectResources } from '@/hooks/useMemberRedirectResources';
import { useMemo, useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { AdminInlineSpinner, AdminCardSkeleton } from '@/components/admin/primitives/AdminLoading';
import { useRedirectWorkspace } from '@/hooks/useRedirectWorkspace';
import { readAnalyticsPage, useRedirectAnalytics } from '@/hooks/useRedirectAnalytics';
import {
  analyticsCsv,
  utcDateRange,
  type AnalyticsFilters,
  type AnalyticsEvent,
  type AnalyticsReport,
} from '@/lib/redirects/analytics';
import { amountMicros, formatRevenue } from '@/lib/redirects/conversions';
import { formatDateTime } from '@/lib/format';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
const CONTROL = 'h-10 w-full rounded-element border bg-background px-4 text-sm';
const day = (date: Date) => date.toISOString().slice(0, 10);
const utcLabel = (value: string) => new Date(value).toISOString().replace('T', ' ').slice(0, 16);
function Series({ report }: { report: AnalyticsReport }) {
  const maximum = Math.max(
    1,
    ...report.series.flatMap((point) => [point.clicks, point.leads, point.sales]),
  );
  const left = report.series[0]?.at,
    right = report.series.at(-1)?.at;
  return (
    <section className="space-y-2" aria-label="Activity over time">
      <h3 className="font-medium">Activity over time · {report.interval} · UTC</h3>
      <svg
        viewBox="0 0 600 160"
        role="img"
        aria-label="Clicks, leads and sales over time"
        className="h-40 w-full text-foreground"
      >
        {[
          ['clicks', 'currentColor'],
          ['leads', 'hsl(var(--primary))'],
          ['sales', 'hsl(var(--muted-foreground))'],
        ].map(([key, color]) => (
          <g key={key}>
            <polyline
              fill="none"
              stroke={color}
              strokeWidth="2"
              strokeDasharray={key === 'sales' ? '2 4' : key === 'leads' ? '8 4' : undefined}
              points={report.series
                .map(
                  (point, index) =>
                    `${report.series.length < 2 ? 300 : 10 + (index / (report.series.length - 1)) * 580},${150 - (point[key as 'clicks' | 'leads' | 'sales'] / maximum) * 140}`,
                )
                .join(' ')}
            />
            {report.series.map((point, index) => (
              <circle
                key={point.at}
                cx={
                  report.series.length < 2 ? 300 : 10 + (index / (report.series.length - 1)) * 580
                }
                cy={150 - (point[key as 'clicks' | 'leads' | 'sales'] / maximum) * 140}
                r={report.series.length === 1 ? 3 : 2}
                fill={color}
              >
                <title>
                  {utcLabel(point.at)} · {key}: {point[key as 'clicks' | 'leads' | 'sales']}
                </title>
              </circle>
            ))}
          </g>
        ))}
      </svg>
      <div className="flex flex-wrap justify-between gap-2 text-xs text-muted-foreground">
        <span>{left ? utcLabel(left) : 'No events'}</span>
        <span>{right ? utcLabel(right) : ''}</span>
      </div>
      <p className="text-xs">Clicks (solid) · Leads (long dash) · Sales (dotted)</p>
    </section>
  );
}
function download(events: AnalyticsEvent[]) {
  const object = URL.createObjectURL(
    new Blob([analyticsCsv(events)], { type: 'text/csv;charset=utf-8' }),
  );
  const anchor = document.createElement('a');
  anchor.href = object;
  anchor.download = 'queerguide-link-events.csv';
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(object), 1000);
}
interface AnalyticsDialogProps {
  links: InventoryRedirect[];
  initialLink?: string;
  initialFolder?: string;
  initialTag?: string;
  onClose: () => void;
}
export function RedirectAnalyticsDialog(props: AnalyticsDialogProps) {
  const workspace = useRedirectWorkspace();
  return <AnalyticsDialogContent {...props} workspace={workspace} />;
}
export function MemberRedirectAnalyticsDialog(
  props: AnalyticsDialogProps & { principalId: string },
) {
  const workspace = useMemberRedirectResources(props.principalId);
  return <AnalyticsDialogContent {...props} workspace={workspace} />;
}
function AnalyticsDialogContent({
  links,
  initialLink,
  initialFolder,
  initialTag,
  onClose,
  workspace,
  principalId,
}: AnalyticsDialogProps & {
  principalId?: string;
  workspace: {
    data?: { folders: { id: string; name: string }[]; tags: { id: string; name: string }[] };
    isError: boolean;
    error: Error | null;
  };
}) {
  const [customer, setCustomer] = useState<string | null>(null);
  const [range, setRange] = useState('30'),
    [start, setStart] = useState(() => day(new Date(Date.now() - 29 * 86400000))),
    [end, setEnd] = useState(() => day(new Date()));
  const [draft, setDraft] = useState<AnalyticsFilters>({
    ...(initialLink ? { linkIds: [initialLink] } : {}),
    ...(initialFolder ? { folderId: initialFolder } : {}),
    ...(initialTag ? { tagId: initialTag } : {}),
    excludeBots: true,
    interval: 'day',
  });
  const [filters, setFilters] = useState<AnalyticsFilters>(() => ({
    ...draft,
    ...utcDateRange(start, end),
  }));
  const [showFilters, setShowFilters] = useState(false);
  const [live, setLive] = useState(false),
    [formError, setFormError] = useState(''),
    [exporting, setExporting] = useState(false),
    [exportError, setExportError] = useState('');
  const { report, events } = useRedirectAnalytics(filters, live, principalId);
  const rows = events.data?.pages.flatMap((page) => page.data) ?? [];
  const managed = useMemo(
    () =>
      links
        .filter((link) => link.manualId && link.source.startsWith('/go/'))
        .sort((a, b) => a.source.localeCompare(b.source)),
    [links],
  );
  const set = (key: keyof AnalyticsFilters, value: unknown) =>
    setDraft((previous) => {
      const result = { ...previous };
      if (value === undefined || value === '') delete result[key];
      else Object.assign(result, { [key]: value });
      return result;
    });
  const apply = () => {
    try {
      setFormError('');
      setFilters({ ...draft, ...(range === 'all' ? {} : utcDateRange(start, end)) });
    } catch (error) {
      setFormError(error instanceof Error ? error.message : 'Invalid dates');
    }
  };
  const exportAll = async () => {
    setExporting(true);
    setExportError('');
    try {
      const all: AnalyticsEvent[] = [];
      let cursor = null as { at: string; id: string } | null;
      do {
        const page = await readAnalyticsPage(
          filters,
          report.data!.snapshot,
          cursor,
          100,
          principalId,
        );
        all.push(...page.data);
        cursor = page.nextCursor;
      } while (cursor);
      download(all);
    } catch (error) {
      setExportError(error instanceof Error ? error.message : 'Export failed');
    } finally {
      setExporting(false);
    }
  };
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !exporting) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-5xl grid-cols-1 overflow-y-auto [&>*]:min-w-0">
        <DialogHeader>
          <DialogTitle>Link analytics</DialogTitle>
          <DialogDescription>
            Recorded clicks, leads and sales. Filters use event dates in UTC. Location is based on
            network metadata; earlier records can have unknown device or city data.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-wrap items-center justify-between gap-4">
          <p className="text-sm">
            {filters.start || filters.end
              ? `${filters.start ? filters.start.slice(0, 10) : 'first record'} to ${filters.end ? new Date(Date.parse(filters.end) - 1).toISOString().slice(0, 10) : 'now'} · UTC`
              : 'All recorded dates'}{' '}
            ·{' '}
            {filters.linkIds
              ? (managed.find((link) => link.manualId === filters.linkIds![0])?.source ??
                'Selected links')
              : principalId
                ? 'All accessible links'
                : 'All managed links'}
          </p>
          <Button
            variant="outline"
            size="sm"
            aria-expanded={showFilters}
            onClick={() => setShowFilters((previous) => !previous)}
          >
            {showFilters ? 'Hide filters' : 'Filter report'}
          </Button>
        </div>
        {showFilters && (
          <form
            className="space-y-4"
            onSubmit={(event) => {
              event.preventDefault();
              apply();
            }}
          >
            <div className="grid gap-4 sm:grid-cols-3">
              <div className="space-y-2">
                <Label htmlFor="analytics-link">Managed link</Label>
                <select
                  id="analytics-link"
                  className={CONTROL}
                  value={draft.linkIds?.[0] ?? ''}
                  onChange={(event) =>
                    set('linkIds', event.target.value ? [event.target.value] : undefined)
                  }
                >
                  <option value="">
                    {principalId ? 'All accessible links' : 'All managed links'}
                  </option>
                  {managed.map((link) => (
                    <option key={link.manualId} value={link.manualId!}>
                      {link.source}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-folder">Folder</Label>
                <select
                  id="analytics-folder"
                  className={CONTROL}
                  value={draft.folderId ?? ''}
                  onChange={(event) => set('folderId', event.target.value)}
                >
                  <option value="">All folders</option>
                  {workspace.data?.folders.map((folder) => (
                    <option key={folder.id} value={folder.id}>
                      {folder.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-tag">Tag</Label>
                <select
                  id="analytics-tag"
                  className={CONTROL}
                  value={draft.tagId ?? ''}
                  onChange={(event) => set('tagId', event.target.value)}
                >
                  <option value="">All tags</option>
                  {workspace.data?.tags.map((tag) => (
                    <option key={tag.id} value={tag.id}>
                      {tag.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-range">Date range</Label>
                <select
                  id="analytics-range"
                  className={CONTROL}
                  value={range}
                  onChange={(event) => {
                    const value = event.target.value;
                    setRange(value);
                    if (['7', '30', '90'].includes(value)) {
                      setStart(day(new Date(Date.now() - (Number(value) - 1) * 86400000)));
                      setEnd(day(new Date()));
                    }
                    if (value === 'all') set('interval', 'month');
                  }}
                >
                  <option value="7">Last 7 days</option>
                  <option value="30">Last 30 days</option>
                  <option value="90">Last 90 days</option>
                  <option value="custom">Custom dates</option>
                  <option value="all">All recorded dates</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-start">Start date (UTC)</Label>
                <Input
                  id="analytics-start"
                  type="date"
                  disabled={range === 'all'}
                  value={start}
                  onChange={(event) => {
                    setRange('custom');
                    setStart(event.target.value);
                  }}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-end">End date (UTC)</Label>
                <Input
                  id="analytics-end"
                  type="date"
                  disabled={range === 'all'}
                  value={end}
                  onChange={(event) => {
                    setRange('custom');
                    setEnd(event.target.value);
                  }}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-event">Event</Label>
                <select
                  id="analytics-event"
                  className={CONTROL}
                  value={draft.event ?? 'all'}
                  onChange={(event) => set('event', event.target.value)}
                >
                  <option value="all">All events</option>
                  <option value="click">Clicks</option>
                  <option value="lead">Leads</option>
                  <option value="sale">Sales</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-interval">Time interval</Label>
                <select
                  id="analytics-interval"
                  className={CONTROL}
                  value={draft.interval ?? 'day'}
                  onChange={(event) => set('interval', event.target.value)}
                >
                  {['hour', 'day', 'week', 'month'].map((value) => (
                    <option key={value}>{value}</option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="analytics-qr">Source</Label>
                <select
                  id="analytics-qr"
                  className={CONTROL}
                  value={draft.qr === undefined ? '' : String(draft.qr)}
                  onChange={(event) =>
                    set('qr', event.target.value === '' ? undefined : event.target.value === 'true')
                  }
                >
                  <option value="">Link and QR</option>
                  <option value="true">QR only</option>
                  <option value="false">Link only</option>
                </select>
              </div>
            </div>
            <details>
              <summary className="cursor-pointer text-sm font-medium">
                Location, device and referral filters
              </summary>
              <div className="mt-4 grid gap-4 sm:grid-cols-3">
                {(
                  [
                    'country',
                    'city',
                    'device',
                    'browser',
                    'os',
                    'domain',
                    'referrer',
                    'variant',
                  ] as const
                ).map((key) => (
                  <div className="space-y-2" key={key}>
                    <Label htmlFor={'analytics-' + key}>
                      {key === 'os'
                        ? 'Operating system'
                        : key === 'country'
                          ? 'Country code'
                          : key === 'variant'
                            ? 'A/B variant'
                            : key[0].toUpperCase() + key.slice(1)}
                    </Label>
                    <Input
                      id={'analytics-' + key}
                      value={draft[key] ?? ''}
                      placeholder="All"
                      maxLength={key === 'country' ? 7 : 253}
                      list={'analytics-values-' + key}
                      onChange={(event) =>
                        set(
                          key,
                          key === 'country' ? event.target.value.toUpperCase() : event.target.value,
                        )
                      }
                    />
                    <datalist id={'analytics-values-' + key}>
                      {report.data?.breakdowns[key]?.map((item) => (
                        <option key={item.label} value={item.label} />
                      ))}
                    </datalist>
                  </div>
                ))}
              </div>
            </details>
            <div className="flex flex-wrap items-center gap-4">
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={draft.excludeBots !== false}
                  onChange={(event) => set('excludeBots', event.target.checked)}
                />
                Exclude detected bots
              </label>
              <Button type="submit">Apply filters</Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => {
                  setDraft({ excludeBots: true, interval: 'day' });
                }}
              >
                Clear draft filters
              </Button>
            </div>
            {formError && (
              <p role="alert" className="text-destructive">
                {formError}
              </p>
            )}
          </form>
        )}
        <RedirectSavedReports
          principalId={principalId}
          filters={filters}
          onLoad={(saved) => {
            const { start: _start, end: _end, ...dimensions } = saved;
            setDraft(dimensions);
            setFilters(saved);
            setRange(saved.start || saved.end ? 'custom' : 'all');
            if (saved.start) setStart(day(new Date(saved.start)));
            if (saved.end) setEnd(day(new Date(Date.parse(saved.end) - 1)));
          }}
        />
        {workspace.isError && (
          <p role="alert">Folder and tag options could not load. {workspace.error?.message}</p>
        )}
        <div className="flex flex-wrap items-center justify-between gap-4">
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={live}
              onChange={(event) => setLive(event.target.checked)}
            />
            Live updates (every 5 seconds)
          </label>
          <div className="flex flex-wrap gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={report.isFetching}
              onClick={() => void report.refetch()}
            >
              Refresh report
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!report.data || exporting || report.isError}
              onClick={() => void exportAll()}
            >
              {exporting ? (
                <AdminInlineSpinner label="Exporting events" />
              ) : (
                'Export all matching events'
              )}
            </Button>
          </div>
        </div>
        {report.isPending && <AdminCardSkeleton />}
        {report.isError && (
          <div role="alert">
            <p className="text-destructive">Could not load analytics. {report.error.message}</p>
          </div>
        )}
        {exportError && (
          <p role="alert" className="text-destructive">
            {exportError}
          </p>
        )}
        {report.data && (
          <>
            <div className="flex flex-wrap gap-6 tabular-nums">
              {Object.entries(report.data.totals).map(([name, total]) => (
                <p key={name}>
                  <strong>{total.toLocaleString()}</strong> {name}
                </p>
              ))}
              {report.data.revenue.map((item) => (
                <p key={item.currency}>
                  <strong>{formatRevenue(amountMicros(item.amount), item.currency)}</strong> revenue
                </p>
              ))}
            </div>
            <Series report={report.data} />
            <div className="grid gap-6 sm:grid-cols-3">
              {['country', 'city', 'device', 'browser', 'os', 'referrer', 'domain', 'qr'].map(
                (key) => (
                  <section key={key}>
                    <h3 className="mb-2 font-medium">
                      {key === 'os'
                        ? 'Operating systems'
                        : key === 'qr'
                          ? 'Link / QR'
                          : key[0].toUpperCase() + key.slice(1)}{' '}
                      · top 10
                    </h3>
                    <ul className="space-y-2 text-xs">
                      {report.data!.breakdowns[key]?.slice(0, 10).map((item) => (
                        <li className="flex justify-between gap-2" key={item.label}>
                          <span className="break-all">{item.label}</span>
                          <span className="tabular-nums">{item.count.toLocaleString()}</span>
                        </li>
                      ))}
                    </ul>
                  </section>
                ),
              )}
            </div>
            <section className="space-y-2" aria-label="Event activity">
              <h3 className="font-medium">Event activity</h3>
              {events.isError && (
                <div role="alert">
                  <p>{events.error.message}</p>
                  <Button variant="outline" onClick={() => void events.refetch()}>
                    Retry events
                  </Button>
                </div>
              )}
              {events.isPending && <AdminCardSkeleton />}
              <div className="overflow-x-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr>
                      {[
                        'When',
                        'Event',
                        'Link',
                        'Customer',
                        'Country / city',
                        'Device / browser',
                        'Revenue',
                      ].map((name) => (
                        <th className="p-2 text-left" key={name}>
                          {name}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((event) => (
                      <tr key={event.id}>
                        <td className="whitespace-nowrap p-2">
                          {formatDateTime(event.occurred_at)}
                        </td>
                        <td className="p-2">
                          {event.event_name} ({event.kind})
                        </td>
                        <td className="p-2">{event.source ?? 'Unknown'}</td>
                        <td className="p-2">
                          {event.customer_key ? (
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => setCustomer(event.customer_key)}
                            >
                              {event.customer_key}
                            </Button>
                          ) : (
                            '—'
                          )}
                        </td>
                        <td className="p-2">
                          {event.country ?? 'Unknown'} · {event.city}
                        </td>
                        <td className="p-2">
                          {event.device} · {event.browser}
                        </td>
                        <td className="p-2">
                          {event.amount && event.currency
                            ? formatRevenue(amountMicros(event.amount), event.currency)
                            : '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {events.hasNextPage && (
                <Button
                  variant="outline"
                  size="sm"
                  disabled={events.isFetchingNextPage}
                  onClick={() => void events.fetchNextPage()}
                >
                  {events.isFetchingNextPage ? (
                    <AdminInlineSpinner label="Loading events" />
                  ) : (
                    'Load older events'
                  )}
                </Button>
              )}
              {events.isSuccess && rows.length === 0 && (
                <p className="text-sm text-muted-foreground">No events match these filters.</p>
              )}
            </section>
          </>
        )}
        {customer && (
          <RedirectCustomerDetails customer={customer} onClose={() => setCustomer(null)} />
        )}
      </DialogContent>
    </Dialog>
  );
}
