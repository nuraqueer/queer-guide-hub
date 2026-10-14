import type { PublicRedirectReport } from '../../../supabase/functions/_shared/redirect-reports';
export class DashboardError extends Error {
  constructor(
    message: string,
    public status: number,
    public passwordRequired: boolean,
  ) {
    super(message);
  }
}
export async function readSharedRedirectReport(
  id: string,
  password: string,
  signal?: AbortSignal,
): Promise<PublicRedirectReport> {
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id))
    throw new DashboardError('Dashboard unavailable', 404, false);
  const response = await fetch('/api/redirects/public-report', {
    method: password ? 'POST' : 'GET',
    cache: 'no-store',
    credentials: 'omit',
    referrerPolicy: 'no-referrer',
    signal,
    headers: {
      Authorization: 'Bearer qg_report_' + id,
      ...(password ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(password ? { body: JSON.stringify({ password }) } : {}),
  });
  const data = await response.json();
  if (!response.ok)
    throw new DashboardError(
      data.error ?? 'Dashboard unavailable',
      response.status,
      data.passwordRequired === true,
    );
  return data as PublicRedirectReport;
}
