import {
  publicWebhookIp,
  webhookUrl,
  resolveWebhookAddress,
  webhookSignatures,
  sendPinnedWebhook,
  type WebhookNetwork,
} from '../../_shared/redirect-webhook-transport.ts';
import {
  webhookInput,
  webhookPage,
  dispatchRedirectWebhooks,
} from '../../_shared/redirect-webhooks.ts';
const assert = (ok: unknown, message = 'Assertion failed') => {
  if (!ok) throw new Error(message);
};
const rejects = async (fn: () => unknown, code?: string) => {
  try {
    await fn();
  } catch (error) {
    if (code) assert((error as { code: string }).code === code);
    return;
  }
  throw new Error('Expected rejection');
};
Deno.test(
  'public addresses and URL normalization reject private/reserved destinations',
  async () => {
    for (const ip of [
      '127.0.0.1',
      '10.2.3.4',
      '169.254.169.254',
      '100.64.1.2',
      '198.18.0.1',
      '192.0.2.2',
      '::1',
      'fc00::1',
      '::ffff:8.8.8.8',
      '2001:db8::1',
      '2002::1',
    ])
      assert(!publicWebhookIp(ip), ip);
    for (const ip of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111'])
      assert(publicWebhookIp(ip), ip);
    for (const url of [
      'https://127.1/a',
      'https://0x7f000001/a',
      'https://user:password@example.org/a',
      'http://example.org',
      'https://example.org/#x',
      'https://foo.local/',
      'https://example.org/\r\nx',
    ])
      await rejects(() => webhookUrl(url));
    assert(
      webhookUrl('https://RECEIVER.example.org.:443/events').href ===
        'https://receiver.example.org/events',
    );
  },
);
const dns =
  (addresses: string[]): typeof fetch =>
  async (input) => {
    const q = new URL(String(input)),
      host = q.searchParams.get('name'),
      type = q.searchParams.get('type');
    return Response.json({
      Status: 0,
      Question: [{ name: host }],
      Answer: addresses
        .filter((ip) => ip.includes(':') === (type === 'AAAA'))
        .map((ip) => ({ name: host, type: ip.includes(':') ? 28 : 1, data: ip })),
    });
  };
Deno.test(
  'DNS rejects mixed public/private answers and uses fixed credential-free resolver',
  async () => {
    const url = webhookUrl('https://receiver.example.org/events');
    await rejects(
      () => resolveWebhookAddress(url, new AbortController().signal, dns(['8.8.8.8', '10.0.0.1'])),
      'dns_blocked',
    );
    assert(
      (await resolveWebhookAddress(
        url,
        new AbortController().signal,
        dns(['2606:4700:4700::1111', '8.8.8.8']),
      )) === '8.8.8.8',
    );
    await rejects(
      () => resolveWebhookAddress(url, new AbortController().signal, dns([])),
      'dns_unavailable',
    );
  },
);
Deno.test('Standard Webhooks signatures match HMAC bytes and cover exact raw body', async () => {
  const secret = 'whsec_' + btoa(String.fromCharCode(...new Uint8Array(32).fill(7))),
    id = crypto.randomUUID(),
    body = '{"amount":"1.123456"}';
  const key = await crypto.subtle.importKey(
    'raw',
    new Uint8Array(32).fill(7),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = btoa(
    String.fromCharCode(
      ...new Uint8Array(
        await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.123.${body}`)),
      ),
    ),
  );
  assert((await webhookSignatures([secret], id, 123, body)) === 'v1,' + signature);
  assert(
    (await webhookSignatures([secret, secret], id, 123, body)) ===
      'v1,' + signature + ' v1,' + signature,
  );
  assert((await webhookSignatures([secret], id, 123, body + ' ')) !== 'v1,' + signature);
});
function fakeNetwork(response: string, peer = '8.8.8.8') {
  let bytes = new TextEncoder().encode(response),
    written = '',
    closed = false;
  const socket = {
    remoteAddr: { hostname: peer },
    async read(buffer: Uint8Array) {
      if (!bytes.length) return null;
      const count = Math.min(3, buffer.length, bytes.length);
      buffer.set(bytes.subarray(0, count));
      bytes = bytes.slice(count);
      return count;
    },
    async write(buffer: Uint8Array) {
      const count = Math.min(buffer.length, 7);
      written += new TextDecoder().decode(buffer.subarray(0, count));
      return count;
    },
    close() {
      closed = true;
    },
    async handshake() {
      return { alpnProtocol: 'http/1.1' };
    },
  };
  const network: WebhookNetwork = {
    async connect(options) {
      assert(options.hostname === '8.8.8.8');
      assert(options.port === 443);
      return socket;
    },
    async startTls(_socket, options) {
      assert(options.hostname === 'receiver.example.org');
      return socket;
    },
  };
  return { network, request: () => written, closed: () => closed };
}
Deno.test(
  'pinned transport writes exact body and original Host, parses chunked response and Retry-After',
  async () => {
    const fixture = fakeNetwork(
      'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nTransfer-Encoding: chunked\r\nRetry-After: 120\r\n\r\n4\r\nslow\r\n0\r\n\r\n',
    );
    const result = await sendPinnedWebhook(
      webhookUrl('https://receiver.example.org/events?q=1'),
      '8.8.8.8',
      '{"x":1}',
      { 'webhook-id': crypto.randomUUID() },
      fixture.network,
      new AbortController().signal,
    );
    assert(result.status === 429 && result.retryAfter === 120 && result.excerpt === 'slow');
    assert(fixture.request().startsWith('POST /events?q=1 HTTP/1.1\r\n'));
    assert(fixture.request().includes('Host: receiver.example.org\r\n'));
    assert(fixture.request().endsWith('\r\n\r\n{"x":1}'));
    assert(fixture.closed());
  },
);
Deno.test(
  'transport never follows redirects, rejects peer changes and malformed HTTP',
  async () => {
    const fixture = fakeNetwork(
      'HTTP/1.1 302 Found\r\nLocation: https://127.0.0.1/\r\nContent-Length: 0\r\n\r\n',
    );
    assert(
      (
        await sendPinnedWebhook(
          webhookUrl('https://receiver.example.org/events'),
          '8.8.8.8',
          '{}',
          {},
          fixture.network,
          new AbortController().signal,
        )
      ).status === 302,
    );
    await rejects(
      () =>
        sendPinnedWebhook(
          webhookUrl('https://receiver.example.org/events'),
          '8.8.8.8',
          '{}',
          {},
          fakeNetwork('', '1.1.1.1').network,
          new AbortController().signal,
        ),
      'network_error',
    );
    await rejects(
      () =>
        sendPinnedWebhook(
          webhookUrl('https://receiver.example.org/events'),
          '8.8.8.8',
          '{}',
          {},
          fakeNetwork('HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx').network,
          new AbortController().signal,
        ),
      'invalid_response',
    );
  },
);
Deno.test('management rejects invalid shapes and unsafe cursors', async () => {
  await rejects(() => webhookInput({ name: 'x', url: 'https://127.0.0.1' }, true));
  await rejects(() => webhookInput({ version: crypto.randomUUID() }));
  await rejects(() => webhookPage(new URLSearchParams('cursor=9223372036854775808'), true));
  await rejects(() => webhookPage(new URLSearchParams('limit=1&limit=2')));
  assert(
    webhookInput(
      {
        name: ' Receiver ',
        url: 'https://example.org',
        eventTypes: ['sale.created', 'sale.created'],
      },
      true,
    ).name === 'Receiver',
  );
});
Deno.test('dispatcher resolves before preparing secrets and reports cancelled leases', async () => {
  const id = crypto.randomUUID(),
    lease = crypto.randomUUID();
  let calls: string[] = [];
  const db = {
    async rpc(name: string) {
      calls.push(name);
      if (name === 'prune_redirect_webhooks') return { data: {}, error: null };
      if (name === 'claim_redirect_webhook_deliveries')
        return {
          data:
            calls.filter((x) => x === name).length === 1
              ? [{ id, lease, url: 'https://receiver.example.org/events' }]
              : [],
          error: null,
        };
      if (name === 'prepare_redirect_webhook_delivery')
        return { data: null, error: { code: '42501' } };
      return { data: { state: 'cancelled' }, error: null };
    },
  };
  const result = await dispatchRedirectWebhooks(
    db,
    {
      connect() {
        throw new Error('Must not connect');
      },
      startTls() {
        throw new Error('Must not connect');
      },
    },
    async (input, options) => {
      assert(!calls.includes('prepare_redirect_webhook_delivery'));
      assert(options?.credentials === 'omit' && options?.redirect === 'error');
      return dns(['8.8.8.8'])(input, options);
    },
  );
  assert(result.cancelled === 1 && result.claimed === 1);
});
