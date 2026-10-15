import { describe, expect, it, vi } from 'vitest';
import { onRequest } from './qr';
const context = (request: Request, fetcher?: typeof fetch) =>
  ({
    request,
    env: fetcher ? { REDIRECT_QR: { fetch: fetcher } } : {},
  }) as unknown as Parameters<typeof onRequest>[0];
describe('public QR service binding relay', () => {
  it('forwards only image parameters and the trusted edge IP, without API credentials or cookies', async () => {
    const fetcher = vi.fn<typeof fetch>(async (input) => {
      const request = input as Request;
      expect(request.url).toBe('https://qr.internal/api/qr?url=https%3A%2F%2Fexample.com%2F');
      expect([...request.headers.keys()]).toEqual(['cf-connecting-ip']);
      return new Response('image', {
        headers: { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' },
      });
    });
    const response = await onRequest(
      context(
        new Request('https://queer.guide/api/qr?url=https%3A%2F%2Fexample.com%2F', {
          headers: {
            Authorization: 'Bearer private',
            Cookie: 'private',
            'cf-connecting-ip': '192.0.2.1',
            'X-Forwarded-For': 'spoofed',
          },
        }),
        fetcher,
      ),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toBe('image/png');
    expect(await response.text()).toBe('image');
  });
  it('passes bounded-body ownership to the service and returns sanitized errors when unconfigured/offline', async () => {
    const body = JSON.stringify({ url: 'https://example.com/' });
    const fetcher = vi.fn<typeof fetch>(async (input) => {
      expect(await (input as Request).text()).toBe(body);
      throw new Error('private internal URL');
    });
    const response = await onRequest(
      context(
        new Request('https://queer.guide/api/qr', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body,
        }),
        fetcher,
      ),
    );
    expect(fetcher).toHaveBeenCalledOnce();
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain('private');
    const missing = await onRequest(
      context(new Request('https://queer.guide/api/qr', { method: 'HEAD' })),
    );
    expect(missing.status).toBe(503);
    expect(await missing.text()).toBe('');
  });
});
