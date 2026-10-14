import { initWasm } from '@resvg/resvg-wasm';
import rasterizer from '@resvg/resvg-wasm/index_bg.wasm';
import { qrImageResponse } from './handler';
let initialized: Promise<void> | undefined;
export default {
  fetch(request: Request, env: RedirectQrEnv) {
    return qrImageResponse(
      request,
      env.SUPABASE_URL,
      async (key) => (await env.QR_RATE_LIMITER.limit({ key })).success,
      () => (initialized ??= initWasm(rasterizer)),
    );
  },
} satisfies ExportedHandler<RedirectQrEnv>;
