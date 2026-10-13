# Redirects: Dub Links feature parity

Objective: analyze https://dub.co/links and implement the same capabilities in
Redirects. This ledger preserves the full scope. A feature is complete only
after schema, server behavior, UI/API, tests, and applicable runtime evidence
exist. Existing local tools are a foundation, not proof of parity or deployment.

## Requirements and evidence ledger

| Requirement | Required behavior / evidence | Current state |
| --- | --- | --- |
| Branded links | Custom slug, random slug, editable destination; shorten arbitrary public HTTP(S) URLs | Candidate: public HTTP(S) destinations; private/local targets rejected; custom domains missing |
| UTM builder | Source/medium/campaign/term/content/referral; preserve queries/fragments | Candidate: six campaign fields including referral; query/fragment preservation tested |
| Shared UTM templates | Named workspace templates, apply/save/edit/delete in builder/settings | Candidate: implemented locally; pending release |
| Folders | Create/rename/delete/move links, folder-filtered list and analytics | Candidate: implemented locally; pending release |
| Tags | Multiple colored tags, create/rename/delete, shareable filtered list and analytics | Candidate: implemented locally; pending release |
| Comments | Team-visible comment on link card, clickable hyperlinks | Candidate: implemented locally; pending release |
| Folder permissions | Explicit view/edit permissions for team members, enforced in database/API | Missing |
| Bulk actions | Create/update/upsert/delete, folder/tag assignment, archive, import/export, QR export | Partial: CSV import and basic export |
| Custom previews | Uploaded OG image (1200×630, ≤1.5 MB), title≤120, description≤240, video API, crawler unfurl | Missing |
| AI previews | Generate title/description from destination content using configured AI provider | Missing |
| Custom domains | Verify ownership/DNS, multiple domains, primary domain, redirects on branded hostname | Missing |
| Domain defaults | Root/not-found redirects, default expiration URL, workspace/domain QR logos | Missing |
| Deep links | iOS/Android association files, app page routes, fallback and deferred attribution | Missing |
| Geo targeting | Country-specific destinations and default fallback | Candidate: country rules and fallback tested |
| Device targeting | iOS/Android destinations, evaluated before geo | Candidate: iOS/Android priority tested |
| A/B testing | 2–5 destinations, weighted traffic≥10%, end date≤6 weeks, manual winner/end | Candidate: editor/resolver implemented locally |
| A/B completion | Device→geo→experiment priority; choose winner by sales/conversions, rates, clicks; leads fallback | Candidate: selection/metrics now fed by verified native and scoped server conversion ingestion |
| Password links | Password challenge, hashed secret, no disclosure/bypass, scoped access | Partial: hashed protection, atomic attempt throttling and signed IP relay; custom password logo pending |
| Expiration | Date and expired destination URL, live enforcement without stale cached rules | Candidate: date/phrase parser, custom fallback and live enforcement tested |
| Link cloaking | Explicit iframe mode with accurate iframe limitations, standard redirect fallback | Missing |
| Branded QR | Dots square/circle/joined; marker center square/circle; border square/rounded/circle; colors | Candidate: all dot/marker/color controls; scan verification before export |
| QR logos/export | Workspace/domain/logo precedence and hide; SVG/PNG/JPG; clipboard image and image URL | Partial: per-export logo, PNG/JPG/SVG, image/data URL copy; workspace/domain precedence pending |
| Click analytics | Real-time totals/time series, custom date/filter/export, countries/cities/devices/browsers/OS/referrers | Candidate: SQL totals/time series, date/dimension filters, export and bounded live refresh; release pending |
| Conversion tracking | Click attribution, leads/signup/sale/revenue, trusted conversion ingestion and application hooks | Candidate: scoped ingestion, consented signup and verified Stripe hooks implemented locally |
| Customer insights | Customer journey across click→lead→sale with private event timeline | Partial: private ID-based cross-link paginated journeys; identity enrichment missing |
| Live events | Paginated live click/lead/sale stream, real events rather than demo data | Candidate: private click/lead/sale activity with keyset pages and five-second refresh |
| Shared dashboards | Revocable scoped sharing, sanitized aggregate-only default | Missing |
| Custom reports | Custom dates, granular link/folder/tag/domain/geo/device/event filters | Partial: date/dimension report UI and API; saved definitions and sharing missing |
| Integrations | Segment and GTM adapters; native configured integrations and provider callbacks | Missing |
| REST API | Authenticated/scoped link CRUD/upsert/count/list, analytics/events, folders/tags, bulk operations | Partial: conversion and read analytics/events endpoints, scoped credentials; management resources missing |
| SDKs | TypeScript, Python, Go, Ruby, PHP wrappers and runnable examples covering management/tracking | Missing |
| Webhooks | Signed click/lead/sale events, retries, delivery history, replay and secret rotation | Missing |

## Primary references

- [Product feature list](https://dub.co/links)
- [UTM templates](https://dub.co/help/article/how-to-create-utm-templates)
- [Tags](https://dub.co/help/article/how-to-use-tags)
- [Custom previews](https://dub.co/help/article/custom-link-previews)
- [QR customization](https://dub.co/help/article/custom-qr-codes)
- [Device priority](https://dub.co/help/article/device-targeting)
- [A/B rules and winner selection](https://dub.co/help/article/ab-testing)
- [Comments](https://dub.co/help/article/link-comments)

## Implementation order

1. Durable shared templates, folders/tags, and comments for managed links and
   automatic/static inventory records using stable resource keys.
2. Link policies and resolver: public destinations, live expiry, password,
   targeting/experiments, previews/cloaking, deep links and domains.
3. Brand QR options and reusable link settings; folder permissions and bulk tools.
4. Attributed clicks/conversions, customer journeys, live reports and sharing.
5. Authenticated API/SDKs/webhooks/integrations and deployment verification.

Keep work on `feature/redirects-dub-parity`; the existing combined release has a
different owner. Do not push to its integration branch or merge this work into
it while that release is validating. External provider/domain configuration
must be evidenced; unconfigured adapters are not marked fully achieved.

## Checkpoint: workspace foundation

Implemented candidate on `feature/redirects-dub-parity`:
- Shared template CRUD and application, including referral tags and replacement
  of previous UTM values without disturbing destination queries/fragments.
- Folder/tag CRUD, multi-tag assignment, URL folder/tag filters, colored badges,
  private comments with clickable HTTP hyperlinks, and inheritance when creating
  a new campaign from an existing rule or active folder.
- Stable semantic inventory IDs for static/client aliases across source edits.
- Admin-scoped database policies and an atomic campaign-create/assignment RPC.

Evidence: `supabase/tests/redirect_link_workspace.sql` passed with schema and
fixtures rolled back, including denied ordinary-member reads/writes, unknown-tag
rollback, duplicate-tag normalization, invalid template rejection, and FK delete
behavior. Workspace/creation/list tests pass; targeted lint and formatting pass;
frontend build passes; typecheck has no new errors after matching the inherited
release's dependency tree. Desktop/mobile screenshots under
`outputs/redirect-dub-parity/` use explicitly labelled preview fixtures. No
production schema or source integration branch has been modified for this phase.

This is not completion of the overall objective. Folder permissions, filtered
analytics, bulk operations and all other missing ledger requirements remain.
Next: link policy schema/resolver and UI for public destinations, targeting,
experiments, password/expiry, previews, domains and deep links; then analytics,
conversion ingestion, API/SDK/webhooks and release verification.

## Checkpoint: targeting and access policies

Implemented locally: arbitrary public HTTP(S) destination validation; live iOS/Android
and country routing; weighted 2–5 variant experiments with six-week deadlines,
manual winner/end and automatic conversion/click-based selection; password
challenge with salted PBKDF2-SHA256 hashes; natural-language expiration entry
and optional expired destination. HEAD requests do not count. Password query
values are stripped before destination/event storage. Protected destinations
are no longer exposed by the legacy public Data API policy or resolver RPC.

A service-only atomic visit RPC checks active windows and quotas before increment
and event insertion. Variant metrics avoid click inflation when multiple
conversions join one click. Conversion storage is a foundation; no conversion
ingestion or customer-journey feature is claimed yet.

Evidence: 60 policy/resolver/editor/validation/proxy/expiration/authorization
tests passed. The actual admin edge handler denies absent/invalid identity and
non-admin roles, and sends hashes rather than passwords to privileged storage.
`npm run test:redirect-sql` runs the workspace/policy migrations and RLS, atomic
creation, quota, expiry and metrics SQL tests in isolated PGlite PostgreSQL.
Frontend and Cloudflare proxy builds passed; typecheck reported no new errors;
migration-version validation passed against the integration base. Desktop/mobile
policy screenshots use fixtures, not a production account.

No production schema was changed. These are release candidates, not live parity.
Password attempt throttling, branded password pages, custom previews/cloaking,
custom domains/deep links and all other unimplemented ledger items remain.

## Checkpoint: branded QR exports

Implemented locally: square/circle/joined dots; square/rounded/circle marker
borders; square/circle centers; custom dark/light colors; optional PNG/JPG
logo with size limits/removal; 1024px PNG/JPG and scalable SVG downloads;
clipboard image and image data URL. Rendering preserves reserved QR positioning
and timing modules, four-module quiet space and high error correction.

Every export is generated locally. It tries standard QR masks and decodes the
actual PNG pixels and compressed JPG before enabling exports. Low-contrast,
inverted, unsafe image markup and unverified outputs expose an error. No stale
preview/export remains available when a new style is invalid. A data URL is
labelled accurately; no public hosted image URL is claimed.

Evidence: 25 QR/link-builder tests passed, including all 18 style combinations
with exact payload recovery from PNG and JPG, logo-bearing codes, invalid
styles and correct export formats/filenames. Targeted lint passed. Desktop and
mobile fixture screenshots are in `outputs/redirect-dub-parity/qr-styled-*.jpg`.
Browser clipboard actions showed success, and the browser-generated styled PNG
was independently decoded to the exact tracked URL. Native download completion
is not observable in this browser; export handlers/formats are tested.

Workspace/domain defaults, persistent per-link QR branding and hosted image
URLs remain outstanding. This is still local development, not deployment or
completion of the broader parity objective.

## Checkpoint: conversion ingestion and native application hooks

Implemented locally: optional recorded click IDs on destination URLs; scoped,
expiring/revocable server credentials with private hashes; trusted lead/sale
ingestion, stable event-ID retries/conflicts, direct sale and customer-anchor
attribution; native confirmed signup validation and existing analytics-consent
gating; native Stripe paid checkout/async completion/renewal attribution using
verified signatures and stable purchase IDs. The donation FK preserves the
financial ledger when a campaign is deleted.

Private cohort reports now show lead/sale/customer totals and per-currency
revenue, using exact PostgreSQL decimal strings and integer accumulation.
Customer journeys are cross-link, chronological and keyset-paginated; historical
paths survive slug edits. Conversion data feeds the existing experiment metrics.
Admin setup supports one-time secret copying and selected-link scope/revocation.

Evidence: 42 focused tests across 13 files passed; the SQL suite passed against
isolated PGlite. `test:redirect-stripe` executes the actual webhook source with
genuine Stripe signature verification and WebCrypto, then writes into the
isolated database, proving paid-only revenue, retry deduplication, renewal
attribution and A/B metrics. It creates no payments or provider requests.
Typecheck has no new errors. Frontend/proxy builds and targeted lint passed;
final checks are recorded in `tmp/conversion-*`. Fixture screenshots are in
`outputs/redirect-dub-parity/conversion-*.jpg`.

See `docs/guides/redirect-conversions.md` for setup, contracts, units, retry rules
and remaining limitations. Production migration/provider/browser delivery is
not verified. This does not complete the full parity objective: identity
enrichment, advanced/live/shared reports, full API/SDK/webhooks/integrations,
domains/deep links/previews/cloaking, folder RBAC/bulk tools and persistent QR
branding still require implementation and release evidence.

## Checkpoint: detailed analytics and event activity

Implemented locally: bounded visitor family classification and Cloudflare city/
region/continent relay; QR visit markers; invoker/RLS analytics views and SQL
aggregation; UTC zero-filled time series; link/folder/tag/date/event/location/
device/browser/OS/domain/referrer/variant/QR filters; exact per-currency revenue;
receipt-time keyset event pages; complete matching-event CSV export; optional
five-second live polling; read-only or combined scoped credentials and read API.

The dashboard opens on results, with expandable filters, usable mobile layout,
and chart patterns/point tooltips. Reports expose normalized dimensions without
raw queries, agents, IP hashes or password fields. Earlier metadata is honestly
Unknown. Scoped read restrictions intersect user filters.

Evidence: analytics SQL tests passed in isolated PostgreSQL, including real
report calls, UTC zero buckets, folder/tag intersections, scope boundaries,
paging, exact revenue, referrer redaction and ordinary-user RLS. 25 focused tests
passed across seven files; UI filter tests also passed after the responsive
change. Native signed-Stripe regression, frontend/proxy builds, migration gates,
targeted lint and typecheck (no new errors) passed. Screenshots under
`outputs/redirect-dub-parity/analytics-*.jpg` use labelled fixtures.

`docs/guides/redirect-analytics.md` documents endpoints, filters, UTC semantics,
heuristics, limits and remaining scope. No production schema was mutated. This
is another candidate checkpoint, not completion of the full parity objective.

## Checkpoint: password attempt throttling

Implemented locally: atomic service-only reservations before password hashing;
10 attempts per link/client hash and 1,000 per link in a 15-minute window;
bounded counters and lazy retention cleanup; no-count HEAD/empty GET challenge;
fail-closed unavailable limiter; destination-free 429 challenge with Retry-After
preserved by the branded proxy. Successful checks consume the same budget.

An optional shared REDIRECT_RELAY_SECRET signs the visitor IP, slug and timestamp
between Pages and the resolver. Without valid recent proof, only the upstream
CDN address is used; arbitrary X-Forwarded-For is ignored. Deployments must
configure the matching secret to distinguish visitors behind the Pages relay.
Without it, relay visitors may share a conservative bucket.

Evidence: 19 policy/resolver/relay/proxy tests and isolated PostgreSQL suite passed for
limits, independent clients, resets, global budget, retention, private access,
invalid hashes, signed forwarding/tampering and retry behavior. Native Stripe
regression, proxy compilation, targeted lint and migration-version validation
passed; typecheck reports no new errors (704 inherited). Production
migration and matching relay-secret setup remain pending. Password-page logo
customization and the other remaining parity requirements are still outstanding.
