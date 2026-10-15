import {
  sendPinnedWebhook,
  webhookUrl,
  type WebhookNetwork,
  type WebhookSocket,
} from '../../_shared/redirect-webhook-transport.ts';
const assert = (ok: unknown) => {
  if (!ok) throw new Error('TLS assertion failed');
};
Deno.test(
  'native pinned TCP upgrade validates original TLS hostname with a trusted fixture CA',
  async () => {
    const cert = await Deno.readTextFile(
        new URL('../../../../tmp/webhook-tls/cert.pem', import.meta.url),
      ),
      key = await Deno.readTextFile(
        new URL('../../../../tmp/webhook-tls/key.pem', import.meta.url),
      ),
      ca = await Deno.readTextFile(new URL('../../../../tmp/webhook-tls/ca.pem', import.meta.url));
    const server = Deno.listenTls({
      hostname: '127.0.0.1',
      port: 0,
      cert,
      key,
      alpnProtocols: ['http/1.1'],
    });
    const port = (server.addr as Deno.NetAddr).port;
    const serving = (async () => {
      const conn = await server.accept();
      try {
        const request = new Uint8Array(8192);
        let text = '';
        while (!text.endsWith('\r\n\r\n{}')) {
          const count = await conn.read(request);
          if (count === null) throw new Error('Missing request');
          text += new TextDecoder().decode(request.subarray(0, count));
        }
        assert(text.includes('Host: receiver.example.org\r\n'));
        await conn.write(new TextEncoder().encode('HTTP/1.1 204 No Content\r\n\r\n'));
      } finally {
        conn.close();
      }
    })();
    // Injection exists only in this test. Production always connects to the resolved IP.
    let actual: Deno.TcpConn | null = null;
    const network: WebhookNetwork = {
      async connect(options) {
        assert(options.hostname === '8.8.8.8' && options.port === 443);
        actual = await Deno.connect({ hostname: '127.0.0.1', port });
        return {
          remoteAddr: { hostname: '8.8.8.8' },
          read: actual.read.bind(actual),
          write: actual.write.bind(actual),
          close: actual.close.bind(actual),
        } as WebhookSocket;
      },
      async startTls(_socket, options) {
        assert(options.hostname === 'receiver.example.org');
        return Deno.startTls(actual!, { ...options, caCerts: [ca] });
      },
    };
    try {
      const result = await sendPinnedWebhook(
        webhookUrl('https://receiver.example.org/events'),
        '8.8.8.8',
        '{}',
        {},
        network,
        new AbortController().signal,
      );
      assert(result.status === 204);
      await serving;
    } finally {
      server.close();
    }
  },
);
Deno.test('native TLS rejects a trusted certificate for the wrong original hostname', async () => {
  const cert = await Deno.readTextFile(
      new URL('../../../../tmp/webhook-tls/cert.pem', import.meta.url),
    ),
    key = await Deno.readTextFile(new URL('../../../../tmp/webhook-tls/key.pem', import.meta.url)),
    ca = await Deno.readTextFile(new URL('../../../../tmp/webhook-tls/ca.pem', import.meta.url));
  const server = Deno.listenTls({ hostname: '127.0.0.1', port: 0, cert, key });
  const port = (server.addr as Deno.NetAddr).port;
  const serving = (async () => {
    const conn = await server.accept();
    try {
      await conn.handshake();
    } catch {
      /* Expected peer rejection. */
    } finally {
      conn.close();
    }
  })();
  let actual: Deno.TcpConn | null = null;
  const network: WebhookNetwork = {
    async connect() {
      actual = await Deno.connect({ hostname: '127.0.0.1', port });
      return {
        remoteAddr: { hostname: '8.8.8.8' },
        read: actual.read.bind(actual),
        write: actual.write.bind(actual),
        close: actual.close.bind(actual),
      };
    },
    async startTls(_socket, options) {
      return Deno.startTls(actual!, { ...options, caCerts: [ca] });
    },
  };
  try {
    let rejected = false;
    try {
      await sendPinnedWebhook(
        webhookUrl('https://wrong.example.org/events'),
        '8.8.8.8',
        '{}',
        {},
        network,
        new AbortController().signal,
      );
    } catch (error) {
      rejected = (error as { code: string }).code === 'tls_error';
    }
    assert(rejected);
    await serving;
  } finally {
    server.close();
  }
});
