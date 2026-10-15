/** Public image generation. The destination is encoded, never fetched/resolved. */
export const onRequest: PagesFunction<{ REDIRECT_QR?: Fetcher }> = async ({ request, env }) => {
  const headers = {
    'Cache-Control': 'no-store',
    'X-Robots-Tag': 'noindex',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'Access-Control-Allow-Origin': '*',
    'Content-Type': 'application/json',
  };
  if (!env.REDIRECT_QR)
    return new Response(
      request.method === 'HEAD' ? null : JSON.stringify({ error: 'QR image service unavailable' }),
      { status: 503, headers },
    );
  const url = new URL(request.url);
  url.hostname = 'qr.internal';
  url.protocol = 'https:';
  url.port = '';
  const forwarded = new Headers();
  for (const name of ['content-type', 'cf-connecting-ip']) {
    const value = request.headers.get(name);
    if (value) forwarded.set(name, value);
  }
  try {
    const init = {
      method: request.method,
      headers: forwarded,
      body: request.method === 'POST' ? request.body : undefined,
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(20000)]),
      // Required for streaming bodies in Node-compatible Request implementations.
      duplex: 'half' as const,
    };
    return await env.REDIRECT_QR.fetch(new Request(url, init));
  } catch {
    return new Response(
      request.method === 'HEAD' ? null : JSON.stringify({ error: 'QR image service unavailable' }),
      { status: 503, headers },
    );
  }
};
