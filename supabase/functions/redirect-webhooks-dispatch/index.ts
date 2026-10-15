import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.50.5';
import { requireInternalOrAdmin } from '../_shared/supabase-client.ts';
import { dispatchRedirectWebhooks } from '../_shared/redirect-webhooks.ts';
import type { WebhookNetwork } from '../_shared/redirect-webhook-transport.ts';
Deno.serve(async (req: Request) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
        'X-Robots-Tag': 'noindex',
      },
    });
  if (req.method !== 'POST' || new URL(req.url).search)
    return json({ error: 'Method not supported' }, 405);
  const url = Deno.env.get('SUPABASE_URL') ?? '',
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const db = createClient(url, key, { auth: { persistSession: false } }),
    auth = await requireInternalOrAdmin(req, db);
  if (auth instanceof Response) return auth;
  const network: WebhookNetwork = {
    connect: (options) => Deno.connect({ ...options, transport: 'tcp' }),
    startTls: (socket, options) => Deno.startTls(socket as Deno.TcpConn, options),
  };
  try {
    return json(await dispatchRedirectWebhooks(db, network));
  } catch {
    return json({ error: 'Webhook dispatch unavailable' }, 503);
  }
});
