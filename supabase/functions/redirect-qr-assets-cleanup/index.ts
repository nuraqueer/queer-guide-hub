import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2.50.5';
import { requireInternalOrAdmin } from '../_shared/supabase-client.ts';
import {
  qrAssetStorageConfig,
  dispatchRedirectQrAssetCleanup,
} from '../_shared/redirect-qr-assets.ts';
Deno.serve(async (req: Request) => {
  const json = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), {
      status,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  if (req.method !== 'POST') return json({ error: 'Method not supported' }, 405);
  const url = Deno.env.get('SUPABASE_URL') ?? '',
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const db = createClient(url, key, { auth: { persistSession: false } });
  const auth = await requireInternalOrAdmin(req, db);
  if (auth instanceof Response) return auth;
  try {
    return json(await dispatchRedirectQrAssetCleanup(db, qrAssetStorageConfig(url, key)));
  } catch {
    return json({ error: 'QR asset cleanup unavailable' }, 503);
  }
});
