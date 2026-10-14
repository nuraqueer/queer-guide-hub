# Saved redirect reports and shared dashboards

The analytics dialog can save its current filters and dates as a personal report.
Loading a report restores that selection. Updating requires its current version;
deleting it also deletes its published dashboards. Reports belong to the signed-in
account and are not automatically discoverable by other workspace members.

Publishing requires review and confirmation. A share copies the saved filters,
so later edits to the private report do not expand its audience. By default it
captures the matching managed short links at publication. Workspace owners can
explicitly include future matching links for a folder report without fixed link
IDs. Ordinary members can publish a single link they currently have edit access
to; folder, tag, multiple-link and whole-workspace sharing require a current
workspace owner. Losing the required access suspends a share.

Public URLs use `/share/redirect-report/<opaque UUID>`. Click aggregates are the
default. Conversion counts and exact per-currency revenue require explicit opt-in.
Only country, device, browser, OS and QR breakdowns are published. Raw events,
customer IDs, destination URLs, private filters, city and referrer data are never
part of the public payload. Viewers can use 7/30-day presets or custom UTC dates,
then reset to the published dates. A selection can only narrow a captured start/
end boundary; it cannot change link scope or other saved filters. Unbounded sides
remain selectable. Start is inclusive and end is exclusive. The published report
grain is preserved. The page has no account or private analytics controls.

An optional password is hashed server-side using the existing PBKDF2 password
helper. Passwords travel only in a POST body, never URLs or query-cache keys.
Attempts and public views have database budgets; password work is budgeted before
hash verification. Access, expiry, report version and revocation are checked again
after password verification. The default expiry is 30 days; the publishing UI
also offers 7, 90 or 365 days and no expiry. Revocation is permanent for that URL;
publishing again creates a new URL. There is no auto-refresh or persistent unlock
receipt; manual refresh verifies current access again.

Public JSON and page responses use no-store, no-referrer and noindex headers.
JSON varies on Authorization. The service worker bypasses redirect API and public
report paths entirely and removes old entries from its managed caches during
activation. Failed refreshes clear the rendered report, including its title.
An already opened page cannot erase a screenshot or data a viewer has copied.

## HTTP contract

Registered sessions use the branded `/api/redirects` proxy. All private report
operations require verified account identity; API keys cannot manage reports.

- `GET /reports`: account-owned, keyset-paginated list.
- `POST /reports`: create from a name and filters.
- `GET`, `PATCH`, `DELETE /reports/:id`: read, guarded update and delete.
- `POST /reports/:id/run`: run with current analytics access.
- `GET`, `POST /reports/:id/shares`: list and publish snapshots.
- `DELETE /reports/:id/shares/:shareId`: revoke an owned publication.

Public clients call `GET /public-report` with
`Authorization: Bearer qg_report_<UUID>`. Password-protected reads use POST with
`{"password":"…"}`. Date selections also use POST, with
`{"dates":{"start":"2026-10-01T00:00:00.000Z","end":"2026-10-08T00:00:00.000Z"}}`;
password and dates can be supplied together. Only real UTC ISO instants are
accepted. Clearing either field restores that side of the captured period.
Out-of-bounds/reversed dates return 400 and the page offers date correction/reset
without retaining stale metrics. The response exposes only the selected dates
and published boundaries, alongside sanitized aggregates. Other public filter
overrides are rejected. SQL report/share
functions and tables are service-only; anonymous clients cannot bypass the
sanitizing edge handler. Private analytics and event endpoints also accept POST
filter bodies, avoiding URL limits for larger saved selections.

## Validation and release status

Isolated migrated PostgreSQL tests cover ownership, optimistic versions, captured
scope, current permissions, conversion opt-in, dynamic folders, expiry, budgets,
revocation and private grants. The SDK harness additionally exercises the actual
HTTP handler against that database, including real password verification and
revocation. Vitest covers UI review, password handling, payload sanitization and
revoked-view clearing. `node scripts/test-redirect-report-cache.mjs` executes the
actual worker and verifies network-only routing and targeted cache cleanup.

Native desktop/mobile evidence under `outputs/redirect-dub-parity/` uses labelled
local fixtures with production fetches blocked. No live reports or shares were
created. Production migrations/deployment and controlled-account checks remain
pending. Search indexing opt-in, report SDK methods and
team discovery remain open parity work.


The public date extension is verified with seeded clicks on both half-open date
boundaries, private country/link filters, widening attempts, empty results and
current access loss in PostgreSQL. Actual HTTP tests additionally read date-only
and password-plus-date bodies. Native browser proof covers presets, keyboard-edited
custom dates, reset, mobile layout and revocation (`shared-report-dates-*` images).
The browser automation fill helper did not commit native segmented date changes;
keyboard input verified the actual user interaction. These remain local fixtures.
