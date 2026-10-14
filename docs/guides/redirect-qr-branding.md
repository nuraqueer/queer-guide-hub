# Saved QR styles and branding

Saved shape/color preferences are implemented locally. Durable logo uploads,
workspace/domain logo precedence, hosted QR image URLs and production rollout
remain required; this page does not claim full branding completion.

## Owner preferences

Owner account sessions can GET/PATCH `/qr-styles/workspace` or
`/qr-styles/domains/:domainId`. The domain must exist, but does not need routing
readiness to edit its appearance. Reads return `version` (null before the first
save), explicit `style` overrides, `effectiveStyle` and domainId. Writes require
`{version, style}` and reject stale versions with 409. Keys and member sessions
cannot read or write these private preference endpoints.

Appearance fields are dots (square/circle/joined), border
(square/rounded/circle), center (square/circle), foreground and background
(six-digit hex colors). Only these fields are accepted. A partial object merges
with saved overrides; null field values remove an override. `style: null` clears
all overrides. Resetting preserves the preference record with a new version so
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
Existing per-export PNG/JPG logos remain local to that export. Controlled hosted
logo assets, inherited custom/hide behavior, cleanup and hosted QR image URLs are
the next branding work, followed by controlled Storage/browser/release validation.

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
