# Saved QR styles and branding

Saved appearance and the hosted-logo lifecycle/API are implemented locally.
Saved-logo editor/renderer integration, hosted QR image URLs and production
rollout remain required; this page does not claim full branding completion.

## Owner preferences

Owner account sessions can GET/PATCH `/qr-styles/workspace` or
`/qr-styles/domains/:domainId`. The domain must exist, but does not need routing
readiness to edit its appearance. Reads return `version` (null before the first
save), explicit `style` overrides, `effectiveStyle` and domainId. Appearance writes use
`{version, style}`; logo-only writes are described below. Stale versions return 409. Keys and member sessions
cannot read or write these private preference endpoints.

Appearance fields are dots (square/circle/joined), border
(square/rounded/circle), center (square/circle), foreground and background
(six-digit hex colors). Only these appearance fields are accepted. A partial object merges
with saved overrides; null field values remove an override. `style: null` clears
all appearance overrides. Resetting preserves the preference record with a new version so
stale writers cannot recreate a removed preference unnoticed.

Effective appearance merges built-in defaults → workspace → domain overrides.
SQL validates supported fields and dark-on-light contrast of at least 4.5:1. A
workspace write checks every affected domain combination; invalid changes roll
back with their version. The editor saves the full displayed appearance; reset
restores inheritance. Partial API patches can preserve per-field inheritance.
Preference changes affect future exports, not images already downloaded/printed.

The workspace dialog has **Manage saved QR style**. Expanded domain settings have
the same control for their domain. **Reload QR settings** resolves conflicts
without automatically overwriting a local draft. A draft retains the version at
its first edit even after background query refresh. Reads and local drafts are
account scoped; successful writes invalidate effective-style queries.

## Scoped effective reads

`GET /qr-styles/links/:id` returns `{id, style, source}` where source is default,
workspace or domain. `GET /qr-styles/links?ids=<comma-separated UUIDs>` returns
`{data: [...]}` for 1–100 distinct links. Both require links:read and recheck current
member, folder and ID restrictions/revocation under the ACL lock. Every requested
ID must be visible; a mixed visible/inaccessible batch fails entirely with 404.
No verification, provider, preference-version or other private setup fields leave
these endpoints. Archived/disabled/root links remain readable when accessible.

TypeScript/PHP expose `getQrStyle(id)`, Python/Ruby `get_qr_style(id)`, and Go
`GetQRStyle(ctx, id)`. These methods are read-only and do not grant owner control.
The five native SDK tests use the actual loopback HTTP API and migrated isolated
PostgreSQL to verify their effective-style reads.

## Export behavior

Managed individual exports use the current link ID to load effective styles.
Owner inventory exports for non-managed rules use the workspace style. Cached
settings do not enable export while a fresh read is pending. A failed read offers
retry or an explicit **Use standard style for this export** choice. Local edits
remain export-only and do not modify saved preferences. QR generation is
cancelable and still scan-verifies PNG/JPG before enabling downloads.

Bulk exports resolve scoped styles in one batched request plus a workspace read
when non-managed rules are selected. Each code uses its own saved appearance.
Editing the style controls explicitly applies one common appearance to the
selection; **Use saved QR styles** restores the per-code settings. Preparing a
new ZIP after an account/style/selection change is required before download.
Each generated code retains its canonical URL and QR attribution. Individual
field IDs are unique when several settings editors share a page.

The preference JSON deliberately contains no raster data or arbitrary image URLs.
Existing per-export PNG/JPG logos remain local to that export. The hosted-logo lifecycle/API described below is implemented locally. Connecting
its inherited/custom/hide behavior to the UI/renderers and adding hosted QR image
URLs are next, followed by controlled Storage/browser/release validation.

## Local verification

The SQL suite checks precedence, reset, current scope/revocation, stale versions,
unknown fields and cross-domain contrast rollback. Actual HTTP verifies minimal
single/batch reads, version conflicts, private endpoint/key denial and reset.
UI tests cover background-refresh conflicts, explicit fallback, account isolation,
per-row bulk presets and common overrides. Real QR ZIP tests rasterize and decode
the generated images and verify distinct saved colors in their SVGs. Native
browser evidence uses a labeled fixture for preference responses while running
the real editor and QR generator/scan verifier; production requests are blocked.

Product reference: [Dub domain QR logos](https://dub.co/changelog/custom-qr-code-logo).

## Hosted logo asset API (local backend)

The logo lifecycle/API is implemented locally. Connecting the saved-logo editor
and the individual/bulk renderers to these references remains pending. Existing
exports currently consume saved appearance plus per-export local logos; this API
checkpoint does not claim that saved logos already appear in the UI.

Owners POST `{version, image}` to `/qr-styles/workspace/logo` or
`/qr-styles/domains/:domainId/logo`. Image is bare base64 PNG/JPG bytes, at most
1,500,000 bytes decoded and 1024px per dimension. MIME and dimensions come from
byte inspection; SHA-256 is computed on the server. Caller MIME, asset IDs and URLs
are not accepted. Logos are public image assets, stored under immutable UUID keys
in `redirect-brand-assets`; direct writes/listing by anon/authenticated roles are
restricted. Each upload uses no overwrite, no redirects and a 15-second request.

The owner/preference version is checked before upload and again before attaching
its receipt. Only a matching active reservation can be consumed once, by its
original current owner, before its 15-minute expiry. Stale versions return 409;
owner/key restrictions remain in force after bytes are uploaded. Ambiguous
Storage outcomes return 503 without repeating the POST. Pending records remain
available to cleanup. Limits are 60 reservations per owner/hour, 600 globally/hour
and three live pending uploads per scope; a limit returns 429/Retry-After 900.

Preference PATCH accepts `logoMode: inherit | none | custom` independently of
appearance. Custom requires a previously uploaded active asset for that scope.
Inherit/none retain that uploaded asset for later reuse. `clearLogo: true` drops
its reference and defaults the mode to inherit; combine with explicit none to
clear and hide. Shape/color resets preserve logo choices. Uploading a replacement
attaches it atomically with a new shared preference version.

Owner responses include logoMode and their retained logoAsset. Effective reads
add `effectiveLogo` and `logoSource` (default/workspace/domain/hidden). A domain
custom logo takes precedence over the workspace, none hides it, and inherit uses
the workspace choice. Public metadata contains only id, fixed-bucket key/URL,
MIME, byte length, dimensions and SHA-256. Pending assets, uploader identity,
reservations, leases and cleanup errors remain private. The public URL is derived
from the configured project; no caller-supplied host/path is used.

`redirect-qr-assets-cleanup` accepts an internal secret or a verified admin POST.
It claims three unreferenced expired/retired keys with two-minute leases, deletes
through the Storage API and acknowledges the exact lease. Replaced/cleared assets
have a one-hour read grace period. Failed deletes retry with bounded backoff.
Referenced assets are excluded even when their logo is hidden/inherited. Domain
deletion retains asset metadata. Tombstones stay tracked, are rechecked after one
day and then every 30 days, and cannot be reattached; this catches late physical
uploads after an ambiguous request. Raw Storage metadata is never deleted with
SQL. Cron invokes the worker once per minute only when the configured project URL
and internal invocation secret both exist in Vault. Real cron/Storage/CORS and
cleanup throughput remain part of controlled release validation.

Local migrated SQL, actual owner HTTP with the real bounded Storage transport,
and isolated Storage responses verify attachment, precedence, lost receipts,
permission changes, conflicts, quotas, retries and tombstones. Production Storage
uploads and deletions have not been exercised by this work.
