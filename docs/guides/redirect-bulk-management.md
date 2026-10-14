# Selected redirect management

Select rows individually or use the page checkbox. Selection persists across
pages up to 100 rows; changing filters starts a new selection view. The toolbar
always shows the selected count. Selected CSV export uses the selected records,
while the regular Export button exports the current filtered view. Formula-like
CSV fields are escaped for spreadsheet use.

The active view excludes archived records. Use Archive status to show archived
records or all records, and Restore to bring selected records back. Archive is
workspace organization metadata: URLs continue redirecting, enabled/scheduled/
expiry state and analytics are retained. Folder and tag filters intersect with
archive status. The page's overall inventory total includes archived records.

Move to folder supports Unfiled. Add tag and Remove tag modify only the chosen
tag, retaining other tags and comments. Archive, restore, folder, and tag actions
work across every inventory source through one admin-only atomic PostgreSQL RPC.
If one record or resource is invalid, the entire operation rolls back. Failures
keep the selection for review or retry. Changes are shared workspace state.

Delete selected links is enabled only when every selection is a managed short
link. The confirmation shows all selected sources and requires typing DELETE.
Deletion uses one atomic API batch, permanently removing the short links and
associated analytics, while preserving donation records. Automatic/static/client
routing remains managed at its original source. Uploads already served at public
asset URLs are subject to the presentation guide's retention behavior.

API clients use `PATCH /links/{id}` with `{ "isArchived": true }` to archive and
`false` to restore, or include those fields in atomic bulk updates. List/count
filters accept `isArchived: true` or `false`. Omitting the archive filter keeps
the API's existing all-links behavior. Archival scope uses `links:write`, and
listing uses `links:read`; scoped credentials cannot modify other links.

Local SQL, component, inventory selection, and API-input tests cover the changes.
This candidate still needs production migrations and native browser verification.
Richer import/upsert editing remains separate open parity work.

## QR ZIP export

Select concrete source URLs and choose Export selected QR codes. Wildcard or route
placeholder selections disable this action. Choose a shared dot/marker/color/logo
style and PNG, JPG, SVG, or all three. Prepare QR ZIP verifies the whole selection
before enabling Download QR ZIP. Preparation uses local raster rendering and
scan decoding, with at most 100 links and a 64 MB ZIP limit. It does not upload
images or call destination websites.

The ZIP contains unique numbered image filenames and `manifest.csv`, mapping
inventory ID and source to the exact encoded URL and corresponding files. QR
tracking is included for managed queer.guide /go/ short URLs. Comments/destinations
are not included in the manifest. Any failed verification stops the entire export
and names the source; change the style or selection and prepare again. A style
or format change invalidates a prepared ZIP. Logo decoding completes before
preparation can start. Cancelling or closing stops further image work; a cancel
during ZIP packaging discards its result once packaging completes. No partial
bundle is offered.

The production generator and ZIP contents are verified locally with real raster
images and an independent Python ZIP reader. Local native-browser generation was also checked at desktop and mobile sizes,
and a completed downloaded fixture ZIP passed scan and CRC inspection. Live
production behavior and workspace/domain logo precedence remain unverified or unfinished.
[JSZip generation API](https://stuk.github.io/jszip/documentation/api_jszip/generate_async.html)
documents the archive format used by this implementation.
