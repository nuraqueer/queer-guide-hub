export interface AnalyticsFilters {
  linkIds?: string[];
  folderId?: string;
  tagId?: string;
  start?: string;
  end?: string;
  event?: 'all' | 'click' | 'lead' | 'sale';
  country?: string;
  city?: string;
  device?: string;
  browser?: string;
  os?: string;
  domain?: string;
  referrer?: string;
  variant?: string;
  excludeBots?: boolean;
  qr?: boolean;
  interval?: 'hour' | 'day' | 'week' | 'month';
}
export interface AnalyticsEvent {
  id: string;
  redirect_id: string;
  kind: 'click' | 'lead' | 'sale';
  occurred_at: string;
  received_at: string;
  click_id: string;
  source: string | null;
  event_name: string;
  customer_key: string | null;
  amount: string | null;
  currency: string | null;
  country: string | null;
  city: string;
  region: string;
  continent: string;
  domain: string;
  device: string;
  browser: string;
  os: string;
  is_bot: boolean;
  is_qr: boolean;
  variant_id: string | null;
  referrer: string;
}
export interface AnalyticsReport {
  snapshot: string;
  totals: { clicks: number; leads: number; sales: number; customers: number };
  revenue: { currency: string; amount: string }[];
  series: { at: string; clicks: number; leads: number; sales: number }[];
  breakdowns: Record<string, { label: string; count: number }[]>;
  interval: string;
}
export interface AnalyticsPage {
  data: AnalyticsEvent[];
  snapshot: string;
  nextCursor: { at: string; id: string } | null;
}
export function analyticsCsv(events: AnalyticsEvent[]) {
  const cell = (value: unknown) => {
    const text = String(value ?? '');
    return '"' + (/^[=+\-@\t\r]/.test(text) ? "'" : '') + text.replace(/"/g, '""') + '"';
  };
  const columns = [
    'id',
    'kind',
    'occurred_at',
    'source',
    'event_name',
    'customer_key',
    'amount',
    'currency',
    'country',
    'city',
    'device',
    'browser',
    'os',
    'domain',
    'referrer',
    'is_qr',
    'variant_id',
  ] as const;
  return [
    columns.join(','),
    ...events.map((event) => columns.map((key) => cell(event[key])).join(',')),
  ].join('\r\n');
}
export function utcDateRange(start: string, end: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end))
    throw new Error('Choose a start and end date.');
  const first = new Date(start + 'T00:00:00Z'),
    last = new Date(end + 'T00:00:00Z');
  if (
    !Number.isFinite(+first) ||
    !Number.isFinite(+last) ||
    first.toISOString().slice(0, 10) !== start ||
    last.toISOString().slice(0, 10) !== end ||
    +last < +first
  )
    throw new Error('End date must follow the start date.');
  last.setUTCDate(last.getUTCDate() + 1);
  return { start: first.toISOString(), end: last.toISOString() };
}
