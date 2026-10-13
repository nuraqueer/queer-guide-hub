import type { Env } from '../_lib/sitemap';

/** Keep the public branded URL while the existing resolver owns rules and visits. */
export const onRequest: PagesFunction<Env> = async ({ request, params, env }) => {
  const headers = {
    'Cache-Control': 'no-store',
    'X-Robots-Tag': 'noindex',
    'Referrer-Policy': 'no-referrer',
  };
  if (!['GET', 'HEAD', 'POST'].includes(request.method))
    return new Response('Method not allowed', {
      status: 405,
      headers: { ...headers, Allow: 'GET, HEAD, POST' },
    });
  const slug = String(params.slug ?? '').toLowerCase();
  if (!/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(slug))
    return new Response('Link not found', { status: 404, headers });
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY)
    return new Response('Short links are temporarily unavailable', { status: 503, headers });
  const resolver = new URL('/functions/v1/redirect-handler', env.SUPABASE_URL);
  resolver.searchParams.set('slug', slug);
  const query = new URL(request.url).searchParams.toString();
  if (query) resolver.searchParams.set('q', query);
  const forwarded = new Headers({
    Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
    apikey: env.SUPABASE_ANON_KEY,
  });
  for (const name of ['referer', 'user-agent', 'cf-connecting-ip', 'cf-ipcountry']) {
    const value = request.headers.get(name);
    if (value) forwarded.set(name, value);
  }
  // The resolver's CDN can replace cf-ipcountry with the relay's country.
  const country =
    typeof request.cf?.country === 'string'
      ? request.cf.country
      : request.headers.get('cf-ipcountry');
  if (country) forwarded.set('x-qg-visitor-country', country);
  for (const field of ['city', 'region', 'continent'] as const) {
    const value = request.cf?.[field];
    if (typeof value === 'string') forwarded.set('x-qg-visitor-' + field, value);
  }
  forwarded.set('x-qg-visitor-domain', new URL(request.url).hostname);
  if (request.method === 'POST')
    forwarded.set('Content-Type', request.headers.get('Content-Type') ?? '');
  try {
    const response = await fetch(resolver, {
      method: request.method,
      headers: forwarded,
      body: request.method === 'POST' ? request.body : undefined,
      redirect: 'manual',
      signal: AbortSignal.timeout(8000),
    });
    const status = response.status;
    const location = response.headers.get('Location');
    if ([301, 302, 303, 307, 308].includes(status) && location)
      return new Response(null, { status, headers: { ...headers, Location: location } });
    if (status === 404)
      return new Response(request.method === 'HEAD' ? null : 'Link not found or expired', {
        status: 404,
        headers,
      });
    if (
      [200, 401, 410].includes(status) &&
      response.headers.get('Content-Type')?.startsWith('text/html')
    ) {
      const htmlHeaders = new Headers(headers);
      htmlHeaders.set('Content-Type', 'text/html; charset=utf-8');
      const csp = response.headers.get('Content-Security-Policy');
      if (csp) htmlHeaders.set('Content-Security-Policy', csp);
      return new Response(request.method === 'HEAD' ? null : response.body, {
        status,
        headers: htmlHeaders,
      });
    }
    return new Response('Short links are temporarily unavailable', { status: 502, headers });
  } catch {
    return new Response('Short links are temporarily unavailable', { status: 502, headers });
  }
};
