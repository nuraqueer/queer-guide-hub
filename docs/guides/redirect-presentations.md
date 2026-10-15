# Redirect previews and framed destinations

Managed link settings now include social preview title (≤120 characters),
description (≤240), public HTTPS image/video URLs and an optional framed destination.
Preview title defaults to a generic link title when empty. The editor uploads PNG/JPG
artwork, center-crops it to 1200 × 630 on a white background and encodes JPEG. Both
source and uploaded artwork are limited to 1,500,000 bytes; dimensions above
4096 × 4096 are rejected before client decoding. Original file metadata is not
preserved in the canvas export.

Artwork is public in the `redirect-previews` bucket. Use public campaign images.
Original filenames are not used: paths contain a managed link UUID and random UUID.
Removing/turning off a preview does not delete previous public asset URLs. This
preserves externally cached cards; asset cleanup is a separate lifecycle task.
The migration refuses incompatible existing bucket settings, limits MIME types
and uses restrictive policies to deny direct client writes/listing even when
other Storage policies are permissive. Service upload occurs only after verified
link authorization and input checks. Failed final authorization attempts cleanup.
Production Storage upload/download delivery has not yet been verified.

## Visitor behavior

Known social unfurl agents (Facebook, Twitter/X, LinkedIn, Slack, Discord, WhatsApp,
Telegram, Pinterest) receive OpenGraph title/description/image/video metadata
without consuming a visit or issuing a click ID. Agent identification is heuristic;
it is not authorization. Password checks run before metadata and prevent disclosure
of protected previews. HEAD requests do not record visits. Disabled, scheduled,
expired and quota-limited links retain their existing availability behavior.
Normal browsers continue to redirect when framing is off.

Framing serves an HTML wrapper containing the selected destination in a sandboxed
iframe and a persistent **Open destination directly** link. It records one normal
visit and passes that click ID to the frame/fallback when conversion tracking is
on. The short URL stays in the address bar while the destination loads in the frame.
The wrapper has no scripts, escapes all values and limits its frame CSP to the
selected destination origin. Main/device/geo/experiment destinations must be HTTPS
or site-relative paths. Database triggers also prevent changing an actively framed
link to HTTP. Expired fallbacks use ordinary redirects.

Some sites deny framing using X-Frame-Options/frame-ancestors, redirect to another
origin, or require third-party cookies. The wrapper cannot reliably detect all
cross-origin framing failures. It does not claim automatic frame success; the direct
link is always available. Changing destination security headers is outside this
feature. Social platforms may cache old preview cards; response no-store is not a
promise to purge third-party caches. AI-generated metadata remains pending.

## API and SDK

`GET /api/redirects/links/:uuid/presentation` requires `links:read`.
`PATCH` to that path requires `links:write` and accepts only:

```json
{"preview":{"title":"Community night","description":"Join us","image":"https://example.com/art.jpg","video":"https://example.com/preview.mp4"},"cloaked":true}
```

The preview object replaces previous preview fields. Omitted preview/cloaked fields
are preserved; `preview:null` removes custom metadata and `cloaked:false` disables
framing. Password, tracking, targeting and expiry are preserved. Responses contain
only preview/cloaked fields, not password hashes or destination URLs.

`POST /links/:uuid/preview-image` requires `links:write` and accepts
`{"image":"BASE64_PNG_OR_JPEG"}`. Its bounded JSON limit is 2,100,000 bytes;
decoded bytes must be ≤1,500,000 and artwork exactly 1200 × 630. Raster headers and
dimensions determine MIME/extension rather than a caller filename/content type.
SVG/GIF/WebP and wrong dimensions are rejected. The server stores the public asset
and returns `{image,width,height}` with 201. Uploading alone does not enable a
preview; PATCH the presentation or Save link settings to apply the returned URL.

Each of the five SDKs exposes get/update presentation and upload-preview-image
methods in its native naming style. Supply base64 text from prepared image bytes.
The SDKs do not crop files; the browser editor handles cropping. Selected-link
scope, revocation and expiry are checked in SQL before and after image storage.

## Verification status

Local candidate. Tests cover escaping, metadata/video tags, script-free frame
fallback, real PNG/JPG dimensions, invalid/oversized inputs, password-before-preview,
no crawler visits, one framed visit with attribution and no-count HEAD. SQL tests
cover scoped writes, public RPC denial, restrictive Storage writes, preserved
password/expiry/tracking and HTTPS guards. All five SDKs exercise presentation and
image upload over HTTP into actual source handlers/isolated SQL; file storage uses
a fixture adapter, not production Storage. Component tests cover controls and
concurrent edit preservation. Native browser rendering/upload and production
migration/provider delivery remain unverified.

## Generate a preview draft

`POST /links/{id}/preview-generate` accepts `{}` and requires `links:write`
(or a verified admin session). It uses the link's saved main destination, not an
arbitrary supplied URL or device/experiment destination. It returns only
`{title, description}`; neither the endpoint nor the editor saves this draft.
Review it and press Save to apply it. Generation replaces draft text and retains
artwork, video, and other policy settings. Failures preserve manual text.

Deployment needs `FIRECRAWL_API_KEY` plus the existing Cloudflare AI configuration
(`CF_ACCOUNT_ID` and `CF_AI_API_TOKEN`, or their existing aliases) or
`NVIDIA_API_KEY`. `AI_DISABLED=1` disables generation. Missing configuration returns
503 without reserving spend. Destination page content is sent to Firecrawl and
up to 16,000 characters are sent to the configured AI provider. Use this for
public page content; no page credentials or caller cookies are forwarded.

The edge contacts the fixed Firecrawl v2 scrape endpoint with redirects disabled,
a 12-second transport timeout, no actions, and no document parsers. It never
fetches the destination itself. Direct private/loopback/local URL literals and
URL credentials are rejected; DNS and redirect isolation inside the external
scraping service remain that provider's responsibility. Provider responses are
bounded to 512 KB, inference requests use at most 300 output tokens, zero client
retries, and the existing AI usage telemetry. NVIDIA and Cloudflare fallback
retain the shared client's behavior: Cloudflare uses a 15-second timeout,
NVIDIA uses its shared 45-second transport ceiling, and fallback can add both. Generated JSON has closed keys and the same 120/240
character limits as the editor; malformed output returns 503.

Service-only PostgreSQL reservations atomically enforce 5 requests/link/hour,
10 requests/credential-or-admin/hour, and 60 requests/workspace/hour. Failed
provider calls consume reservations. A 429 includes `Retry-After`. Link scope is
rechecked both at reservation and after generation; revoked credentials cannot
receive the draft. No AI credentials or real page/provider requests are used in
tests. Live provider delivery and native browser rendering remain unverified.

Provider references: [Firecrawl scrape API](https://docs.firecrawl.dev/api-reference/endpoint/scrape)
and [Workers AI compatible API](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/).
