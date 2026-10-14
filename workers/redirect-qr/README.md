# Redirect QR image service

Local implementation; not deployed. A service binding named `REDIRECT_QR` from the
Pages project to `qg-redirect-qr` exposes `functions/api/qr.ts` at `/api/qr`.
The Worker deliberately has no public route or workers.dev/preview URL. Configure
`SUPABASE_URL` to the same fixed project as the app for saved logo reads. It needs
no service-role key, API token, destination fetch, database write or click lookup.
The rate-limit namespace ID in wrangler.jsonc is reserved for this service; verify
it is unused in the deployment account before release.

## HTTP contract

GET/HEAD `/api/qr?url=<URL>` returns an image. Default format PNG, size 1024,
standard appearance, no logo. OPTIONS returns CORS headers. Parameters:

- `url`: absolute HTTP(S), no embedded credentials/whitespace, at most 2048 bytes.
- `format`: `png`, `jpg`, or `svg`.
- `size`: `256`, `512`, or `1024`. Unscannable density/styles return 422.
- `tracked`: `1` adds `qg_qr=1` for a managed custom-domain link; `0` leaves external
  URLs alone. Built-in queer.guide /go/ links retain automatic QR attribution.
- `dots`, `border`, `center`, `foreground`, `background`: the same appearance
  fields/options as the admin QR editor. Colors must be dark on light, with at
  least 4.5:1 contrast. Hash colors must be URL-encoded in a query string.
- `logo`: immutable UUID `.png`/`.jpg` key in `redirect-brand-assets`; `logoHash`
  is its exact lowercase SHA-256. No arbitrary logo URL is accepted.

POST `/api/qr` accepts the same string parameters as JSON (no query string).
`logo` can instead be a PNG/JPG base64 data URI for local artwork, without
`logoHash`. This returns generated image bytes; it does **not** mint a durable
GET URL for the uploaded artwork. Such authoring still requires a controlled
asset/recipe save which does not replace workspace defaults.

PNG/JPG logos are capped at 1,500,000 bytes and 1024px per dimension. Actual PNG
CRC/decoding and bounded JPEG decoding run before embedding. Saved logo responses
are fetched only from the configured public project/bucket/key, with fixed MIME,
SHA-256, bounded streaming, no credentials/redirects and a 10-second timeout.
POST bodies are bounded at 2.1 MB; unknown/duplicate parameters are rejected.
The destination URL is encoded only: generating/retrieving an image cannot count
a click, consume link quota or trigger redirects/password/scheduling behavior.

The renderer shares SVG geometry with the browser, preserving high ECC, reserved
modules and the quiet zone. A bundled pinned resvg Wasm module renders each mask.
Actual pixels must decode to the exact URL; JPG is checked again after compression.
Each Wasm raster and renderer is freed. SVG uses generated markup and embedded
raster artwork only; CSP allows data images and prevents active content.
No fonts or runtime CDN/Wasm downloads are used.

Responses use no-store, no-referrer, nosniff, noindex and public CORS without
credentials. Unexpected errors are sanitized. Only content type and the edge's
CF-Connecting-IP reach the Worker through Pages; client cookies, API credentials
and forwarding headers are discarded. The limiter allows 30 requests/60 seconds
per edge IP using Cloudflare's local rate-limit binding; it is not an exact global
quota. Invocation logs are disabled so URL query payloads are not logged by this
Worker. Platform/project logging and resource budgets still need release review.

## Verification

From the repository root:

```sh
npx tsc -p workers/redirect-qr/tsconfig.json
npx vitest run src/lib/redirects/__tests__/qrHosted.test.ts functions/api/qr.test.ts
npm run test:redirect-qr
npx wrangler deploy --config workers/redirect-qr/wrangler.jsonc --dry-run
```

The native script starts and stops a fresh local workerd instance, verifies actual
SVG/PNG/JPG and inline PNG/JPG logo outputs by independent decoding, HEAD/OPTIONS,
validation and the real local rate limiter. The installed workerd's newest
supported date is 2026-10-13, so the script explicitly overrides that date; the
Worker configuration is 2026-10-14. Set `QR_TEST_COMPATIBILITY_DATE=2026-10-14` once
the local runtime supports it and repeat before release. No remote calls are made.
Native tests specifically catch pngjs's private synchronous zlib API incompatibility;
logo decoding uses its supported streaming API instead.

Saved-default resolution, UI hosted-image copying, durable custom-artwork recipes,
five-SDK URL contracts, real Pages binding/cold starts/resource limits and controlled
production deployment remain follow-ups. The service alone is not full QR parity.
Dependencies are pinned in the root lockfile. resvg-wasm is MPL-2.0, jpeg-js is
BSD-3-Clause, pngjs/node-qrcode/jsQR are MIT; retain their distributed license notices.
