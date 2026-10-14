# Redirects: Dub Links feature parity

Objective: analyze https://dub.co/links and implement the same capabilities in
Redirects. This ledger preserves the full scope. A feature is complete only
after schema, server behavior, UI/API, tests, and applicable runtime evidence
exist. Existing local tools are a foundation, not proof of parity or deployment.

## Requirements and evidence ledger

| Requirement | Required behavior / evidence | Current state |
| --- | --- | --- |
| Branded links | Custom slug, random slug, editable destination; shorten arbitrary public HTTP(S) URLs | Candidate: public HTTP(S) destinations, random slug UI and server allocation; private/local targets rejected; custom domains missing |
| UTM builder | Source/medium/campaign/term/content/referral; preserve queries/fragments | Candidate: six campaign fields including referral; query/fragment preservation tested |
| Shared UTM templates | Named workspace templates, apply/save/edit/delete in builder/settings | Candidate: implemented locally; pending release |
| Folders | Create/rename/delete/move links, folder-filtered list and analytics | Candidate: implemented locally; pending release |
| Tags | Multiple colored tags, create/rename/delete, shareable filtered list and analytics | Candidate: implemented locally; pending release |
| Comments | Team-visible comment on link card, clickable hyperlinks | Candidate: implemented locally; pending release |
| Folder permissions | Explicit view/edit permissions for team members, enforced in database/API | Missing |
| Bulk actions | Create/update/upsert/delete, folder/tag assignment, archive, import/export, QR export | Partial: atomic API batches, archive/restore, cross-page bulk organization/deletion/selected CSV and verified QR ZIP UI; richer import/upsert UI pending |
| Custom previews | Uploaded OG image (1200×630, ≤1.5 MB), title≤120, description≤240, video API, crawler unfurl | Candidate: editor, scoped upload/presentation APIs and crawler HTML; native browser/Storage release pending |
| AI previews | Generate title/description from destination content using configured AI provider | Candidate: scoped draft generator with spend limits; live provider and browser verification pending |
| Custom domains | Verify ownership/DNS, multiple domains, primary domain, redirects on branded hostname | Missing |
| Domain defaults | Root/not-found redirects, default expiration URL, workspace/domain QR logos | Missing |
| Deep links | iOS/Android association files, app page routes, fallback and deferred attribution | Missing |
| Geo targeting | Country-specific destinations and default fallback | Candidate: country rules and fallback tested |
| Device targeting | iOS/Android destinations, evaluated before geo | Candidate: iOS/Android priority tested |
| A/B testing | 2–5 destinations, weighted traffic≥10%, end date≤6 weeks, manual winner/end | Candidate: editor/resolver implemented locally |
| A/B completion | Device→geo→experiment priority; choose winner by sales/conversions, rates, clicks; leads fallback | Candidate: selection/metrics now fed by verified native and scoped server conversion ingestion |
| Password links | Password challenge, hashed secret, no disclosure/bypass, scoped access | Partial: hashed protection, atomic attempt throttling and signed IP relay; custom password logo pending |
| Expiration | Date and expired destination URL, live enforcement without stale cached rules | Candidate: date/phrase parser, custom fallback and live enforcement tested |
| Link cloaking | Explicit iframe mode with accurate iframe limitations, standard redirect fallback | Candidate: HTTPS guarded iframe wrapper and persistent direct fallback; runtime release pending |
| Branded QR | Dots square/circle/joined; marker center square/circle; border square/rounded/circle; colors | Candidate: all dot/marker/color controls; scan verification before export |
| QR logos/export | Workspace/domain/logo precedence and hide; SVG/PNG/JPG; clipboard image and image URL | Partial: per-export logo, PNG/JPG/SVG, image/data URL copy; workspace/domain precedence pending |
| Click analytics | Real-time totals/time series, custom date/filter/export, countries/cities/devices/browsers/OS/referrers | Candidate: SQL totals/time series, date/dimension filters, export and bounded live refresh; release pending |
| Conversion tracking | Click attribution, leads/signup/sale/revenue, trusted conversion ingestion and application hooks | Candidate: scoped ingestion, consented signup and verified Stripe hooks implemented locally |
| Customer insights | Customer journey across click→lead→sale with private event timeline | Partial: private ID-based cross-link paginated journeys; identity enrichment missing |
| Live events | Paginated live click/lead/sale stream, real events rather than demo data | Candidate: private click/lead/sale activity with keyset pages and five-second refresh |
| Shared dashboards | Revocable scoped sharing, sanitized aggregate-only default | Missing |
| Custom reports | Custom dates, granular link/folder/tag/domain/geo/device/event filters | Partial: date/dimension report UI and API; saved definitions and sharing missing |
| Integrations | Segment and GTM adapters; native configured integrations and provider callbacks | Missing |
| REST API | Authenticated/scoped link CRUD/upsert/count/list, analytics/events, folders/tags, bulk operations | Partial: scoped link CRUD/upsert/count/list/mixed bulk, conversions and analytics/events; folder/tag/template resource CRUD with workspace scopes; full policy fields pending |
| SDKs | TypeScript, Python, Go, Ruby, PHP wrappers and runnable examples covering management/tracking | Candidate: five native clients verified through actual HTTP handler and isolated DB; publication/release pending |
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

## Checkpoint: scoped link management API

Implemented locally: managed short-link create/get/update/delete/upsert/list/count,
atomic mixed bulk operations, random slug allocation and generator UI, partial
organization/query/expiry updates, and separate link read/write credential scopes.
Selected-link scope is rechecked in SQL with expiry/revocation; creating new links
requires unrestricted scope. Verified admin sessions supply actor identity; API
keys use the verified credential owner. New destinations use the existing public
URL validation and deny short-link loops. Read projections exclude secret fields.

Actual SQL tests cover scopes, revocation, invalid-assignment and denied-late-batch
rollback, stable upserts, preserved metadata, expiry clearing, deletion cascades,
preserved donation ledger, and keyset pagination/count across 1,101 links. Typed
query/type fixture enums match the production baseline for these operations.
`docs/guides/redirect-link-management-api.md` records the API contract and limits.

This remains a candidate checkpoint. Resource folder/tag REST, policy/password/
preview/domain/deep-link API fields, SDK wrappers, archive/bulk UI/QR exports,
webhooks, integrations and production release evidence remain in the full scope.

Checkpoint validation: 34 focused tests passed across five files. Isolated SQL
and genuine signed-Stripe regression passed. Frontend/proxy builds, migration
versions and targeted lint passed. Browser fixture screenshots of desktop/mobile
credential setup are under `outputs/redirect-dub-parity/link-management-setup-*.jpg`;
no credential was created or revoked in that browser check. The setup now shows
examples matching management-only permissions and collapses the conversion guide.
Typecheck also passed its no-new-errors gate (704 inherited errors).

## Checkpoint: workspace API and five server SDKs

Implemented locally: folder/tag/template create/detail/list/patch/delete,
independent workspace read/write scopes, unrestricted-key enforcement at issuance
and SQL execution, and scope-specific request examples. Selected-link credentials
cannot edit/read shared organization. Existing link metadata survives resource
edits; deleting resources clears assignments without deleting managed links.

Five SDK sources and runnable examples cover management, shared resources,
tracking, analytics and event pages. Clients use timeouts, bounded responses,
redirect refusal, exact string revenue and explicit HTTP errors. No automatic
mutation retry occurs. `test:redirect-sdks` exercises each language through native
HTTP into the actual edge handler and migrated isolated PostgreSQL, not a mock
request recorder. The suite includes deduplicated conversions, 101-row keyset
iteration, shared resource round trips, partial edits, upserts and deletion.

Docs: `sdk/redirects/README.md` and `docs/guides/redirect-workspace-api.md`.
Package publication, production migration/deployment, remaining API policy fields,
folder-member permissions and all outstanding full-parity features remain pending.

Verification: all five native SDK tests and all five runnable examples passed
against the actual handler/database over loopback HTTP. Exact SDK revenue and
example revenue SQL totals passed. The resource SQL suite also verifies two-page
lists/counts, scope/revocation denial, partial updates and assignment cleanup.
28 focused API/input/UI tests passed; standalone SDK TypeScript declarations,
frontend/proxy builds, targeted lint and migration-version validation passed.
App typecheck has no new errors (704 inherited). The attempted native-browser
preview timed out, so browser verification of the new workspace permission
controls remains unproven; component tests and builds are the available evidence.

## Checkpoint: custom previews and framed destinations

Implemented locally: preview title/description/image/video controls, prepared raster
uploads, scoped presentation/upload APIs, metadata HTML for social unfurl agents,
and optional sandboxed frames with a direct fallback. Password checks precede
preview disclosure; crawler metadata is not a counted visit. Frame requests carry
one recorded click and conversion attribution. HTTPS guards cover active targets,
device/geo/experiment rules and later destination edits. Existing protection,
expiry and tracking survive presentation updates. Upload assets remain public;
removing a preview removes its reference, not previously published artwork.

27 focused resolver/API/editor/media tests passed. Isolated SQL tests verify scopes,
protected settings preservation, HTTPS guards and restrictive Storage policies.
All five SDKs exercise new presentation and encoded-image methods against actual
source handlers and SQL; Storage uses a fixture adapter. Native browser preview
and actual Supabase Storage upload/download verification remain outstanding,
along with production migrations/release and AI generation.

See `docs/guides/redirect-presentations.md` for behavior, scope and exact limits.
This does not complete overall parity: every missing/partial ledger row remains.

Final checkpoint checks: nine existing policy/save authorization tests also passed
(36 focused tests total). Five native SDK clients and examples, isolated SQL,
genuine signed-Stripe regression, frontend/proxy builds, SDK declarations,
targeted lint and migration-version gate passed. App typecheck reports no new
errors (704 inherited). No production bucket, schema or deployment was changed.

## Checkpoint: AI preview drafts

Implemented locally: authenticated/scoped `preview-generate` endpoint and editor
button producing reviewable title/description drafts from the saved destination's
public page content, via configured Firecrawl and the shared AI client. Generation
does not save policy or artwork. SQL spend reservations enforce global, actor,
and link hourly limits, including failed calls. Direct destination fetches are
avoided; external scraping network isolation belongs to the provider. Input,
content-response, prompt, and generated JSON limits are enforced. Configuration
and upstream failures preserve manual text. See the presentation guide for setup
and privacy details.

Local proof: helper and editor tests, actual edge-source authorization/revocation/
rate-limit tests, and migrated PostgreSQL reservations. Live provider delivery,
browser rendering, production migrations, and release remain outstanding. Other
open parity requirements above remain in scope; this checkpoint does not close
the full project.

## Checkpoint: archive and selected bulk management

Implemented locally: selection across inventory pages (100-row cap), active/
archived/all views, atomic archive/restore and folder/tag changes across manual,
automatic, static, and client inventory. Archive is organization metadata; it
preserves routing and enabled state. Adding/removing one tag retains other tags
and comments. Managed short-link deletion requires a concrete selected-link list
and typed DELETE confirmation, then uses the existing atomic scoped API. Source-
owned automatic/static rules cannot be deleted through this bulk UI. Selected
CSV export and clearing selection are available.

API link objects/patches/filters accept boolean `isArchived`; the API's default
list remains all managed links, and callers can explicitly request active or
archived records. The TypeScript SDK includes the archive field; other clients
use their existing object dictionaries. SQL rechecks scope and authorization;
ordinary members cannot change archive metadata. Failed batches roll back and
UI errors retain selection. Production migration, native browser evidence,
bulk QR export and the remaining richer import/upsert UI remain outstanding.

Validation for this checkpoint: 43 focused tests across API input/handler,
organization, selected bulk controls, and inventory views passed. Migrated
PostgreSQL tests prove authorization, archive filtering, retained routing state,
metadata preservation and rollback. Five SDK clients and their examples passed
through the actual HTTP handler and isolated SQL again. Lint and migration-version
gates pass; typecheck remains at 704 inherited errors with none new. Production
build passes. These checks do not prove native browser or production behavior.

## Checkpoint: selected QR bundles

Implemented locally: bulk QR export for 1–100 selected concrete source URLs in
PNG, JPG, SVG, or all formats, with common branded style/logo controls shared with
the single-code dialog. A prepared ZIP is offered only after every code passes
actual raster scan verification; unique safe filenames and an ID/source/encoded
URL/file manifest are included. Managed /go/ URLs carry the QR attribution marker.
Wildcard/template routes cannot be exported as concrete codes. Any code failure
rejects the whole bundle and identifies its source. Payload and final ZIP are
bounded to 64 MB. Closing/cancelling aborts between image steps; cancellation
during JSZip packaging discards the result after bounded packaging completes.
Changing format/style invalidates a prepared ZIP; logo loading disables preparing
until the upload is decoded. Exports are local and make no network requests.

Local evidence: real production generator and decoder run using a Sharp raster
canvas adapter, all archived SVG/PNG/JPG images decode correctly, and Python's
standard ZIP reader confirms filenames/count and CRC integrity. This is actual
artifact verification, not native-browser evidence. UI tests cover ready/download,
format/style invalidation, verification failures and cancellation, and single-code
export regressions. Persistent workspace/domain/link style/logo precedence,
hosted image URLs and production release remain open.

Native browser follow-up for this checkpoint: the local fixture at
`/tmp/bulk-qr-preview.html` renders the real dialog with two example URLs and
makes no production reads/writes. Codex IAB generated joined dots/rounded borders/
circle centers in all three formats, completed the ZIP download, and generated
again at a 390×844 mobile breakpoint. The downloaded file contains six scannable
SVG/PNG/JPG files plus the manifest; all exact fixture URLs and CRCs passed both
JSZip/Sharp/jsQR inspection and an independent Python ZIP reader. Desktop/mobile
screenshots and the downloaded fixture ZIP are under the workspace's
`outputs/redirect-dub-parity/bulk-qr-*`. The temporary tab was closed and viewport
reset. This proves local native-browser export, not live redirect attribution or
production deployment. 32 focused tests, lint, production build and typecheck
ratchet (704 inherited errors, none new) pass.
