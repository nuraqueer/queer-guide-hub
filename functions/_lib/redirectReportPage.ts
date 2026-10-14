import { signRedirectRelay } from '../../supabase/functions/_shared/redirect-relay';
import type { Env } from './sitemap';
import type { RouteMeta } from './routeMeta';

const genericMeta: RouteMeta = {
  title: 'Shared link report | Queer Guide',
  description: 'View a published aggregate link report on Queer Guide.',
};
const escapeHtml = (value: string) =>
  value.replace(
    /[&<>"']/g,
    (char) =>
      ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;',
      })[char]!,
  );
export interface RedirectReportPage {
  indexable: boolean;
  meta: RouteMeta;
  body: string;
}
export function setRedirectReportHeaders(headers: Headers, indexable = false) {
  headers.set('Cache-Control', 'no-store');
  headers.set('Referrer-Policy', 'no-referrer');
  headers.set('X-Robots-Tag', indexable ? 'index, follow' : 'noindex, nofollow');
}
/** No token/title registry or cache: every HTML request checks the live publication. */
export async function redirectReportPage(
  env: Env,
  request: Request,
  basePath: string,
): Promise<RedirectReportPage | null> {
  if (!basePath.startsWith('/share/redirect-report/')) return null;
  const closed: RedirectReportPage = { indexable: false, meta: genericMeta, body: '' };
  const id = basePath
    .match(
      /^\/share\/redirect-report\/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\/?$/i,
    )?.[1]
    ?.toLowerCase();
  const url = new URL(request.url);
  // Only canonical, unlocalized, query-free URLs can be indexed.
  if (!id || url.search || url.pathname !== basePath || !env.SUPABASE_URL) return closed;
  try {
    const headers = new Headers({ Authorization: 'Bearer qg_report_' + id });
    if (env.SUPABASE_ANON_KEY) headers.set('apikey', env.SUPABASE_ANON_KEY);
    if (env.REDIRECT_RELAY_SECRET) {
      const relay = await signRedirectRelay(
        request.headers.get('cf-connecting-ip') ?? '',
        'report:' + id,
        env.REDIRECT_RELAY_SECRET,
      );
      if (relay) {
        headers.set('x-qg-relay-ip', relay.ip);
        headers.set('x-qg-relay-time', relay.timestamp);
        headers.set('x-qg-relay-signature', relay.signature);
      }
    }
    const response = await fetch(
      new URL('/functions/v1/redirect-api/public-report', env.SUPABASE_URL),
      {
        headers,
        redirect: 'manual',
        cache: 'no-store',
        signal: AbortSignal.timeout(8000),
      },
    );
    if (!response.ok || !response.headers.get('Content-Type')?.includes('application/json'))
      return closed;
    if (Number(response.headers.get('Content-Length')) > 1024 * 1024) return closed;
    const text = await response.text();
    if (text.length > 1024 * 1024) return closed;
    const data = JSON.parse(text);
    if (
      data?.allowIndexing !== true ||
      typeof data.title !== 'string' ||
      !data.title.trim() ||
      data.title.length > 100 ||
      !Number.isSafeInteger(data.linkCount) ||
      data.linkCount < 0
    )
      return closed;
    const totals = data.report?.totals;
    const metrics =
      data.includeConversions === true ? ['clicks', 'leads', 'sales', 'customers'] : ['clicks'];
    if (!totals || metrics.some((key) => !Number.isSafeInteger(totals[key]) || totals[key] < 0))
      return closed;
    const summary = metrics
      .map((key) => `<div><dt>${key}</dt><dd>${totals[key].toLocaleString('en-US')}</dd></div>`)
      .join('');
    return {
      indexable: true,
      meta: {
        title: data.title + ' | Queer Guide',
        description:
          'Published aggregate link analytics. Individual events and customer identities are private.',
      },
      body: `<main><h1>${escapeHtml(data.title)}</h1><p>Published aggregate link analytics for ${data.linkCount} accessible link${data.linkCount === 1 ? '' : 's'}.</p><dl>${summary}</dl><p>Individual events and customer identities are private. Open the dashboard to select reporting dates and view breakdowns.</p></main>`,
    };
  } catch {
    return closed;
  }
}
