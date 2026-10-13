export interface RedirectConversion {
  id: string;
  click_id: string;
  kind: 'lead' | 'sale';
  event_name: string;
  occurred_at: string;
  customer_key: string | null;
  amount: string | number | null;
  currency: string | null;
}
export interface JourneyEvent {
  id: string;
  kind: 'click' | 'lead' | 'sale';
  occurred_at: string;
  source: string | null;
  event_name: string;
  amount: string | number | null;
  currency: string | null;
  click_id: string;
}
export function amountMicros(amount: string | number): bigint {
  const text = typeof amount === 'number' ? amount.toFixed(6) : amount;
  if (!/^\d+(?:\.\d{1,6})?$/.test(text)) throw new Error('Invalid recorded revenue amount');
  const [whole, fraction = ''] = text.split('.');
  return BigInt(whole) * 1000000n + BigInt(fraction.padEnd(6, '0'));
}
export function currencyRevenue(events: RedirectConversion[]) {
  const sums = new Map<string, bigint>();
  for (const event of events)
    if (event.kind === 'sale' && event.amount !== null && event.currency)
      sums.set(event.currency, (sums.get(event.currency) ?? 0n) + amountMicros(event.amount));
  return [...sums].sort(([a], [b]) => a.localeCompare(b));
}
export function formatRevenue(micros: bigint, currency: string) {
  const formatter = new Intl.NumberFormat(undefined, { style: 'currency', currency });
  const digits = formatter.resolvedOptions().maximumFractionDigits ?? 2;
  const factor = 10n ** BigInt(6 - digits),
    rounded = (micros + factor / 2n) / factor,
    scale = 10n ** BigInt(digits);
  const whole = rounded / scale,
    fraction = (rounded % scale).toString().padStart(digits, '0');
  const integer = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(whole);
  return formatter
    .formatToParts(0)
    .map((part) =>
      part.type === 'integer' ? integer : part.type === 'fraction' ? fraction : part.value,
    )
    .join('');
}
export function conversionSummary(events: RedirectConversion[]) {
  return {
    leads: events.filter((event) => event.kind === 'lead').length,
    sales: events.filter((event) => event.kind === 'sale').length,
    customers: new Set(events.map((event) => event.customer_key).filter(Boolean)).size,
    revenue: currencyRevenue(events),
  };
}
