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
Saved logos and per-export PNG/JPG uploads now feed individual and bulk exports.
Owner settings support reviewed uploads, workspace inheritance, explicit hiding,
reuse of retained custom artwork and reviewed clearing. Each change captures its
observed preference version; conflicts require reload/reselection. Appearance and
logo drafts cannot overwrite each other. Uploaded defaults are publicly hosted;
per-export uploads stay local to that export. Hosted QR output image URLs and
controlled real Storage/release validation remain pending.

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

The lifecycle/API, saved-logo editor and individual/bulk renderers are connected
locally. Effective logos are fetched only from the configured public bucket and
checked against exact byte length, MIME, dimensions and SHA-256 before decoding.
Reads have cancellation/time limits, at most three concurrent asset transfers,
deduplicate repeated references and cap unique logo bytes per batch at 16 MB.
Missing/invalid images block generation until retry, explicit hiding, or an
explicit standard fallback. Hiding bypasses image loading while retaining a fresh
permission-scoped appearance read. A custom per-export logo also takes precedence.

Changing bulk shapes/colors keeps each code's own saved logo. Choosing a custom
logo or hiding logos explicitly applies that choice to the entire selection.
Appearance and logo resets are separate. Account, selection, appearance or logo
changes invalidate prepared artifacts; image bytes are excluded from query keys
and bulk fingerprints.

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

Native browser verification used a labeled local fixture with production requests
blocked. Owner upload/inheritance and per-export hide/restore worked. A downloaded
ZIP retained two distinct SVG logos after a common appearance edit; all four
PNG/JPG images decoded to their canonical tracked URLs. The 390px layout had no
horizontal overflow. These checks simulate API/Storage responses and do not
substitute for a real deployed Storage/CORS/cron check.


## Hosted image service foundation

A local Worker/Pages relay now implements GET/HEAD/POST image generation using the
same SVG geometry and scan checks as downloads. See
[the service contract and verification commands](../../workers/redirect-qr/README.md).
GET supports explicit appearance and fixed-bucket saved logo references; POST also
accepts local PNG/JPG artwork. The relay requires a REDIRECT_QR service binding and
is not deployed. Revocable saved-default image links and five-SDK contracts are
implemented locally, including durable per-image custom artwork; UI hosted-image
copying remains pending. A POST image response
does not create a durable share URL for its local artwork.


Owners/current members/keys can POST `/qr-images` to explicitly publish a live
image for a visible managed link. Owner sessions can instead provide an explicit
HTTP(S) URL for inventory exports. The response includes imageUrls for all three
formats; each opaque capability is returned once and only its hash is stored.
GET `/qr-images?limit=100&cursor=...` lists scoped metadata without secrets. DELETE
`/qr-images/:id` with `{version}` revokes future retrieval. Labels, optional expiry,
appearance overrides and inherit/hide artwork are supported. Default no-expiry
images remain usable until revoked or the creator loses current link access.

Shared requests use `/api/qr?share=...&format=png&size=512`. The Worker resolves only
minimal canonical URL/appearance/public logo metadata through the private-record
capability endpoint. No destination/password/notes/folder or creator data is
exposed, and image generation does not resolve redirects or consume visits/quota.
Current role, member/key scope and folder/link access are rechecked every request.
Creating a QR image does not change workspace defaults; revoked URLs cannot fall
back to different branding. Retention/creation-ledger cleanup is bounded and uses
the existing internal cleanup worker; real cron is still unverified.


Custom artwork publications accept `logo` bare-base64 PNG/JPG in POST /qr-images.
They remain pending/private until the same checked file is rendered/scan-verified,
uploaded to its immutable reserved key and attached after current creator/version
checks. The API returns imageUrls only after publication. Workspace/domain defaults
remain untouched; custom per-image artwork takes precedence. Unknown uploads are
not repeated automatically. Failed pending records have 15-minute expiry and are
pruned after one day; their hourly creation history remains. Stored artwork stays
referenced until revoke/delete, then receives a one-hour read grace before cleanup.
This depends on the fixed site QR service and the existing internal cleanup job;
real gateway/binding/Storage/cron verification is still required before release.
