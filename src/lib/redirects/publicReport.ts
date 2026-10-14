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
  dates: { start?: string; end?: string } = {},
): Promise<PublicRedirectReport> {
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id))
    throw new DashboardError('Dashboard unavailable', 404, false);
  const post = !!password || Object.keys(dates).length > 0;
  const response = await fetch('/api/redirects/public-report', {
    method: post ? 'POST' : 'GET',
    cache: 'no-store',
    credentials: 'omit',
    referrerPolicy: 'no-referrer',
    signal,
    headers: {
      Authorization: 'Bearer qg_report_' + id,
      ...(post ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(post
      ? {
          body: JSON.stringify({
            ...(password ? { password } : {}),
            ...(Object.keys(dates).length ? { dates } : {}),
          }),
        }
      : {}),
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
