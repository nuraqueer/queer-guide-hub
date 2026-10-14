import { parseQrImageRequest } from './request';
import { QrImageError, renderHostedQr } from './render';
export async function qrImageResponse(
  request: Request,
  storageOrigin: string,
  allowRequest: (key: string) => Promise<boolean>,
  initialize: () => Promise<void>,
  fetcher: typeof fetch = fetch,
) {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, HEAD, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Cache-Control': 'no-store',
    'X-Robots-Tag': 'noindex',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; img-src data:; sandbox",
    'Content-Disposition': 'inline; filename="queerguide-qr"',
  };
  const failure = (message: string, status: number) =>
    new Response(request.method === 'HEAD' ? null : JSON.stringify({ error: message }), {
      status,
      headers: {
        ...headers,
        'Content-Type': 'application/json',
        ...(status === 429 ? { 'Retry-After': '60' } : {}),
      },
    });
  if (new URL(request.url).pathname !== '/api/qr') return failure('Endpoint not found', 404);
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (!['GET', 'HEAD', 'POST'].includes(request.method))
    return failure('Method not supported', 405);
  try {
    const key = request.headers.get('cf-connecting-ip') || 'unknown';
    if (!(await allowRequest(key))) return failure('QR image request limit reached', 429);
    const parameters = await parseQrImageRequest(request, storageOrigin, fetcher);
    await initialize();
    request.signal.throwIfAborted();
    const image = renderHostedQr(
      parameters.url,
      parameters.style,
      parameters.format,
      parameters.size,
      request.signal,
    );
    return new Response(request.method === 'HEAD' ? null : image.bytes, {
      headers: {
        ...headers,
        'Content-Type': image.mime,
        'Content-Length': String(image.bytes.byteLength),
      },
    });
  } catch (error) {
    return failure(
      error instanceof QrImageError ? error.message : 'QR image service unavailable',
      error instanceof QrImageError ? error.status : 503,
    );
  }
}
