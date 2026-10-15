import { parseDate } from 'chrono-node';

/** Natural dates use the browser's local time; stored policies use UTC instants. */
export function parseLinkExpiration(value: string, reference = new Date()): string {
  const parsed = parseDate(value.trim(), reference, { forwardDate: true });
  if (!parsed || !Number.isFinite(parsed.getTime()))
    throw new Error(
      'Could not read that expiration. Use a phrase such as “in 2 hours” or the date picker.',
    );
  return parsed.toISOString();
}
