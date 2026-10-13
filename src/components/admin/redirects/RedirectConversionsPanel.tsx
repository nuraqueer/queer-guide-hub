import { AdminInlineSpinner } from '@/components/admin/primitives/AdminLoading';
import { useMemo, useState } from 'react';
import { Button } from '@/components/ui/button';
import { useRedirectConversions, useRedirectCustomerJourney } from '@/hooks/useRedirectConversions';
import { conversionSummary, amountMicros, formatRevenue } from '@/lib/redirects/conversions';
import { formatDateTime } from '@/lib/format';

export function RedirectConversionsPanel({ linkId, days }: { linkId?: string; days: string }) {
  const report = useRedirectConversions(linkId, days),
    [customer, setCustomer] = useState<string | null>(null);
  const summary = useMemo(() => conversionSummary(report.data ?? []), [report.data]);
  const customers = useMemo(
    () => [
      ...new Set(
        report.data?.map((event) => event.customer_key).filter((key): key is string => !!key) ?? [],
      ),
    ],
    [report.data],
  );
  const journey = useRedirectCustomerJourney(customer);
  return (
    <section className="min-w-0 space-y-4 border-t pt-4" aria-label="Conversion report">
      <h3 className="font-medium">Leads and sales</h3>
      <p className="text-sm text-muted-foreground">
        Conversions attributed to visits in this date range, including later purchases. Revenue
        stays in its recorded currency.
      </p>
      {report.isPending && <p role="status">Loading conversion report…</p>}
      {report.isError && (
        <div role="alert">
          <p className="text-destructive">Could not load conversions. {report.error.message}</p>
          <Button variant="outline" size="sm" onClick={() => void report.refetch()}>
            Retry conversions
          </Button>
        </div>
      )}
      {report.data && (
        <>
          <div className="flex flex-wrap gap-6 text-sm tabular-nums">
            <p>
              <strong>{summary.leads.toLocaleString()}</strong>{' '}
              {summary.leads === 1 ? 'lead event' : 'lead events'}
            </p>
            <p>
              <strong>{summary.sales.toLocaleString()}</strong>{' '}
              {summary.sales === 1 ? 'sale event' : 'sale events'}
            </p>
            <p>
              <strong>{summary.customers.toLocaleString()}</strong>{' '}
              {summary.customers === 1 ? 'customer' : 'customers'}
            </p>
            {summary.revenue.map(([currency, micros]) => (
              <p key={currency}>
                <strong>{formatRevenue(micros, currency)}</strong> revenue
              </p>
            ))}
          </div>
          {report.data.length ? (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <caption className="py-2 text-left font-medium">Most recent 25 conversions</caption>
                <thead>
                  <tr>
                    <th className="p-2 text-left">When</th>
                    <th className="p-2 text-left">Event</th>
                    <th className="p-2 text-left">Customer</th>
                    <th className="p-2 text-left">Revenue</th>
                  </tr>
                </thead>
                <tbody>
                  {report.data.slice(0, 25).map((event) => (
                    <tr key={event.id}>
                      <td className="whitespace-nowrap p-2">{formatDateTime(event.occurred_at)}</td>
                      <td className="p-2">
                        {event.event_name} ({event.kind})
                      </td>
                      <td className="p-2">
                        {event.customer_key ? (
                          <Button
                            variant="link"
                            size="sm"
                            onClick={() => setCustomer(event.customer_key)}
                          >
                            {event.customer_key}
                          </Button>
                        ) : (
                          <span>Unknown customer</span>
                        )}
                      </td>
                      <td className="p-2">
                        {event.amount !== null && event.currency
                          ? formatRevenue(amountMicros(event.amount), event.currency)
                          : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              No attributed conversions for these visits. Connect signup or checkout events in
              Conversion setup.
            </p>
          )}
          {customers.length > 25 && (
            <div className="space-y-2">
              <label htmlFor="redirect-journey-customer" className="text-sm">
                Customer journey
              </label>
              <select
                id="redirect-journey-customer"
                className="w-full rounded-element border bg-background p-2 text-sm"
                value={customer ?? ''}
                onChange={(event) => setCustomer(event.target.value || null)}
              >
                <option value="">Choose a customer</option>
                {customers.map((key) => (
                  <option key={key}>{key}</option>
                ))}
              </select>
            </div>
          )}
        </>
      )}
      {customer && (
        <section className="space-y-2" aria-label="Customer journey">
          <div className="flex flex-wrap justify-between gap-2">
            <h4 className="break-all font-medium">Journey: {customer}</h4>
            <Button size="sm" variant="ghost" onClick={() => setCustomer(null)}>
              Close journey
            </Button>
          </div>
          <p className="text-xs text-muted-foreground">
            Recorded clicks, leads and sales across managed links. Times are shown in chronological
            order.
          </p>
          {journey.isPending && <p role="status">Loading customer journey…</p>}
          {journey.isError && (
            <div role="alert">
              <p>{journey.error.message}</p>
              <Button size="sm" variant="outline" onClick={() => void journey.refetch()}>
                Retry journey
              </Button>
            </div>
          )}
          <ol className="space-y-2">
            {journey.data?.pages
              .flatMap((page) => page.data)
              .map((event) => (
                <li key={event.id} className="border-l-2 pl-4 text-sm">
                  <p>
                    {formatDateTime(event.occurred_at)} · {event.event_name} ({event.kind})
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {event.source ?? 'Unknown source'}
                    {event.amount !== null && event.currency
                      ? ' · ' + formatRevenue(amountMicros(event.amount), event.currency)
                      : ''}
                  </p>
                </li>
              ))}
          </ol>
          {journey.hasNextPage && (
            <Button
              variant="outline"
              size="sm"
              disabled={journey.isFetchingNextPage}
              onClick={() => void journey.fetchNextPage()}
            >
              {journey.isFetchingNextPage ? (
                <AdminInlineSpinner label="Loading journey" />
              ) : (
                'Load more journey events'
              )}
            </Button>
          )}
          {journey.data?.pages.every((page) => page.data.length === 0) && (
            <p className="text-sm">No recorded journey events.</p>
          )}
        </section>
      )}
    </section>
  );
}
