import { useState } from 'react';
import { useParams } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { PageContainer } from '@/components/layout/PageContainer';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { amountMicros, formatRevenue } from '@/lib/redirects/conversions';
import { DashboardError, readSharedRedirectReport } from '@/lib/redirects/publicReport';
export function SharedReportView({ id }: { id: string }) {
  const [password, setPassword] = useState(''),
    [submitted, setSubmitted] = useState({ password: '', attempt: 0 });
  const [viewKey] = useState(() => crypto.randomUUID());
  const query = useQuery({
    queryKey: ['redirect-public-report', id, viewKey, submitted.attempt],
    queryFn: ({ signal }) => readSharedRedirectReport(id, submitted.password, signal),
    retry: false,
    gcTime: 0,
    refetchOnWindowFocus: false,
  });
  const error = query.error as DashboardError | null;
  const data = query.isError ? undefined : query.data;
  const metrics: ('clicks' | 'leads' | 'sales')[] = data?.includeConversions
    ? ['clicks', 'leads', 'sales']
    : ['clicks'];
  const maximum = Math.max(
    1,
    ...(data?.report.series.flatMap((p) => metrics.map((metric) => p[metric] ?? 0)) ?? []),
  );
  return (
    <PageContainer>
      <title>Shared link report · Queer Guide</title>
      <meta name="robots" content="noindex,nofollow" />
      <meta name="referrer" content="no-referrer" />
      <div className="space-y-6">
        <header>
          <h1 className="text-3xl font-semibold">{data?.title ?? 'Shared link report'}</h1>
          <p className="text-sm text-muted-foreground">
            Published aggregate analytics. Individual events and customer identities are private.
          </p>
        </header>
        {query.isPending && <p role="status">Loading dashboard…</p>}
        {query.isError && (
          <div className="space-y-4">
            <p role="alert">{error?.message}</p>
            {error?.passwordRequired ? (
              <form
                className="space-y-4"
                onSubmit={(e) => {
                  e.preventDefault();
                  setSubmitted((current) => ({ password, attempt: current.attempt + 1 }));
                }}
              >
                <div className="space-y-2">
                  <Label htmlFor="shared-report-password">Dashboard password</Label>
                  <Input
                    id="shared-report-password"
                    type="password"
                    autoComplete="current-password"
                    required
                    maxLength={256}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                  />
                </div>
                <Button type="submit" disabled={query.isFetching}>
                  View dashboard
                </Button>
              </form>
            ) : (
              <Button
                variant="outline"
                disabled={query.isFetching}
                onClick={() => void query.refetch()}
              >
                Retry dashboard
              </Button>
            )}
          </div>
        )}
        {data && !query.isError && (
          <>
            <div className="flex flex-wrap items-center justify-between gap-4">
              <p className="text-sm">
                {data.linkCount} accessible link{data.linkCount === 1 ? '' : 's'} · Updated{' '}
                {new Date(data.report.snapshot).toLocaleString()} ·{' '}
                {data.scopeMode === 'folder' ? 'Matching folder links' : 'Published link set'}
              </p>
              <Button
                variant="outline"
                disabled={query.isFetching}
                onClick={() => void query.refetch()}
              >
                {query.isFetching ? 'Refreshing…' : 'Refresh dashboard'}
              </Button>
            </div>
            <dl className="grid grid-cols-2 gap-4 sm:grid-cols-4">
              {Object.entries(data.report.totals).map(([key, value]) => (
                <div key={key} className="border-t py-4">
                  <dt className="text-sm capitalize">{key}</dt>
                  <dd className="text-3xl font-semibold">{value.toLocaleString()}</dd>
                </div>
              ))}
            </dl>
            {data.includeConversions && data.report.revenue.length > 0 && (
              <section aria-label="Revenue" className="space-y-2">
                <h2 className="text-xl font-semibold">Revenue by currency</h2>
                {data.report.revenue.map((row) => (
                  <p key={row.currency}>{formatRevenue(amountMicros(row.amount), row.currency)}</p>
                ))}
              </section>
            )}
            <section
              aria-label={data.includeConversions ? 'Activity over time' : 'Clicks over time'}
              className="space-y-2"
            >
              <h2 className="text-xl font-semibold">
                {data.includeConversions ? 'Activity' : 'Clicks'} over time · {data.report.interval}{' '}
                · UTC
              </h2>
              <svg
                className="h-40 w-full"
                viewBox="0 0 600 160"
                role="img"
                aria-label={
                  data.includeConversions
                    ? 'Aggregate activity over time'
                    : 'Aggregate clicks over time'
                }
              >
                {metrics.map((metric) => (
                  <g key={metric}>
                    <polyline
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeDasharray={
                        metric === 'leads' ? '8 4' : metric === 'sales' ? '2 4' : undefined
                      }
                      points={data.report.series
                        .map(
                          (point, index) =>
                            `${data.report.series.length < 2 ? 300 : 10 + (index / (data.report.series.length - 1)) * 580},${150 - ((point[metric] ?? 0) / maximum) * 140}`,
                        )
                        .join(' ')}
                    />
                    {data.report.series.map((point, index) => (
                      <circle
                        key={point.at}
                        cx={
                          data.report.series.length < 2
                            ? 300
                            : 10 + (index / (data.report.series.length - 1)) * 580
                        }
                        cy={150 - ((point[metric] ?? 0) / maximum) * 140}
                        r="3"
                        fill="currentColor"
                      >
                        <title>
                          {new Date(point.at).toISOString()} · {point[metric] ?? 0} {metric}
                        </title>
                      </circle>
                    ))}
                  </g>
                ))}
              </svg>
              {data.includeConversions && (
                <p className="text-xs">Clicks (solid) · Leads (long dash) · Sales (dotted)</p>
              )}
              <div className="flex justify-between gap-2 text-xs">
                <span>{data.report.series[0]?.at.slice(0, 10)}</span>
                <span>{data.report.series.at(-1)?.at.slice(0, 10)}</span>
              </div>
            </section>
            <div className="grid gap-4 sm:grid-cols-2">
              {Object.entries(data.report.breakdowns).map(([dimension, rows]) => (
                <section key={dimension} className="space-y-2 border-t pt-4">
                  <h2 className="text-lg font-semibold capitalize">
                    {dimension === 'os'
                      ? 'Operating systems'
                      : dimension === 'qr'
                        ? 'Link / QR'
                        : dimension}{' '}
                    · events
                  </h2>
                  <ul className="space-y-2">
                    {rows.slice(0, 10).map((row) => (
                      <li key={row.label} className="flex justify-between gap-4">
                        <span>{row.label}</span>
                        <span>{row.count.toLocaleString()}</span>
                      </li>
                    ))}
                  </ul>
                  {!rows.length && (
                    <p className="text-sm text-muted-foreground">No matching activity.</p>
                  )}
                </section>
              ))}
            </div>
            {data.expiresAt && (
              <p className="text-xs text-muted-foreground">
                Dashboard access expires {new Date(data.expiresAt).toLocaleString()}.
              </p>
            )}
          </>
        )}
      </div>
    </PageContainer>
  );
}
export default function SharedRedirectReport() {
  const { reportId = '' } = useParams();
  return <SharedReportView key={reportId} id={reportId} />;
}
