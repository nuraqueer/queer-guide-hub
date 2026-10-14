# Redirects: Dub Links feature parity

Objective: analyze https://dub.co/links and implement the same capabilities in
Redirects. This ledger preserves the full scope. A feature is complete only
after schema, server behavior, UI/API, tests, and applicable runtime evidence
exist. Existing local tools are a foundation, not proof of parity or deployment.

## Requirements and evidence ledger

| Requirement | Required behavior / evidence | Current state |
| --- | --- | --- |
| Branded links | Custom slug, random slug, editable destination; shorten arbitrary public HTTP(S) URLs | Candidate: public HTTP(S) destinations, random slug UI and server allocation; private/local targets rejected; hostname namespaces and signed branded routing implemented locally, pending controlled release |
| UTM builder | Source/medium/campaign/term/content/referral; preserve queries/fragments | Candidate: six campaign fields including referral; query/fragment preservation tested |
| Shared UTM templates | Named workspace templates, apply/save/edit/delete in builder/settings | Candidate: implemented locally; pending release |
| Folders | Create/rename/delete/move links, folder-filtered list and analytics | Candidate: implemented locally; pending release |
| Tags | Multiple colored tags, create/rename/delete, shareable filtered list and analytics | Candidate: implemented locally; pending release |
| Comments | Team-visible comment on link card, clickable hyperlinks | Candidate: implemented locally; pending release |
| Folder permissions | Explicit view/edit permissions for team members, enforced in database/API | Partial: member/machine bindings, folder defaults/overrides, scoped SQL/API, admin editors and member workspace; access request/review/inbox/email queue implemented locally; all-source semantics and delivery/runtime release pending |
| Bulk actions | Create/update/upsert/delete, folder/tag assignment, archive, import/export, QR export | Candidate for managed links: atomic create/update/upsert/deletion API and CSV review/import/export UI, archive/restore, folder/tag assignment and verified QR ZIP; production release pending |
| Custom previews | Uploaded OG image (1200×630, ≤1.5 MB), title≤120, description≤240, video API, crawler unfurl | Candidate: editor, scoped upload/presentation APIs and crawler HTML; native browser/Storage release pending |
| AI previews | Generate title/description from destination content using configured AI provider | Candidate: scoped draft generator with spend limits; live provider and browser verification pending |
| Custom domains | Verify ownership/DNS, multiple domains, primary domain, redirects on branded hostname | Partial: private registry, exact DNS verification, owner UI and stored defaults implemented locally; durable Cloudflare lifecycle/TLS checks implemented locally; hostname namespaces, signed relay/resolver, routing health, background proof renewal and inventory/CSV/QR/API/SDK fields implemented locally; ready choices, owner primary preference and tracked/member builders implemented locally; legacy raw-table creator, real provider proof and release pending |
| Domain defaults | Root/not-found redirects, default expiration URL, workspace/domain QR logos | Partial: root/not-found/expiry settings and signed-host resolver implemented locally; managed root-link policies, QR/logo precedence and release pending |
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
| Shared dashboards | Revocable scoped sharing, sanitized aggregate-only default | Candidate: saved snapshots, explicit dynamic folders, password/expiry/revoke, aggregate-only UI, date selection and live opt-in indexing implemented locally; runtime release pending |
| Custom reports | Custom dates, granular link/folder/tag/domain/geo/device/event filters | Partial: date/dimension report UI/API, personal saved definitions and scoped sharing implemented locally; team discovery and runtime release pending |
| Integrations | Segment and GTM adapters; native configured integrations and provider callbacks | Missing |
| REST API | Authenticated/scoped link CRUD/upsert/count/list, analytics/events, folders/tags, bulk operations | Partial: scoped link CRUD/upsert/count/list/mixed bulk, conversions and analytics/events; folder/tag/template resource CRUD with workspace scopes; scoped targeting/password/tracking/preview policy endpoints; domain fields/filter/canonical URLs implemented locally; deep-link fields and release pending |
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
- [Public dashboards and sharing controls](https://dub.co/help/article/share-analytics)

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

## Checkpoint: managed CSV review, upsert and export

Implemented locally: primary Import workflow offers create/update-by-ID/upsert-by-
slug, pasted or uploaded CSV, a review of exact normalized values and one atomic
Apply. Supported management fields round trip via the scoped selected-ID CSV
export. Quoted commas/newlines/quotes, BOM/CRLF, typed JSON, explicit null/empty
array clearing, duplicate identities and closed headers are handled. Empty cells
omit changes. Spreadsheet-safe commentJson preserves comments exactly. The bulk
API payload bound is now 2.1 MB, matching the import size bound; ordinary single-
link writes remain at 64 KB. Real 100-row requests above 64 KB are tested. The
existing path importer is retained with the quoted parser and stronger validation;
its row-by-row results remain explicit, not claimed as atomic upsert.

Evidence: 36 focused tests in four files plus the four managed-dialog tests passed
(the dialog worker was retried alone after a startup timeout under resource
contention). Actual CSV source → migrated PostgreSQL proves create/upsert/update,
metadata preservation, all supported CSV field round trips, transaction rollback
and revoked-token rejection. Lint, production build and the typecheck ratchet
(704 inherited errors, none new) pass. No new database migration is required.

Native browser proof uses a local fixture that blocks production fetches and
simulates Apply receipts. Quoted two-row upsert review, exact expandable values,
success/duplicate-submit states and real template download were verified. Python's
CSV reader confirms the downloaded template. Desktop/mobile screenshots are under
`outputs/redirect-dub-parity/managed-import-*`. The 390-pixel mobile dialog has
scrollWidth=clientWidth=390; only the 340-pixel review region scrolls to hold its
576-pixel table. Viewport was reset and temporary tab closed. Production API
import/export and remaining policy/domain/permissions/report/integration work
remain outstanding; the complete goal remains active.

## Checkpoint: scoped policy API and five SDKs

Implemented locally: GET/PATCH managed-link policy endpoints with links:read/write
and selected-link scope enforcement, partial top-level atomic merge/null removal,
expiry synchronization, password set/remove/flag-only responses and bounded hash
reservations. The existing admin writer now shares the row-lock order used by
presentation and policy writers. Merged framing rules retain their HTTPS guard.
The policy validator rejects malformed/falsy dates/maps/experiments and unknown
nested A/B fields. All five SDKs expose policy methods; TypeScript exports policy
DTO/nullable-patch types. The branded proxy preserves Retry-After.

Evidence: actual migrated SQL proves scope/revocation, preserved fields/passwords,
explicit clearing, failed-expiry rollback and independent password budgets. Native
clients exercise the real HTTP edge handler/SQL, set/remove protection, verify
stored hashes using the real PBKDF2 verifier and preserve other settings. Target
selection remains unchanged; its regression checks accompany validator changes.
See the policy API guide for the wire contract and limits. Production migrations,
release, domain/deep-link API fields and other ledger requirements remain open.

Final validation for this checkpoint: 42 API/save/proxy tests and 31 policy/
resolver/validation regressions pass, including revocation after password work
and malformed experiment weights without incidental coercion exceptions. All
five SDK clients and examples pass via real loopback HTTP and migrated SQL;
stored hashes verify with the real password verifier. SQL includes expiry-failure
rollback and independent actor/link/global budget checks. Build, lint, SDK types,
and migration versions pass. App typecheck remains 704 inherited errors, none
new. Pages production/test types now have separate configurations; the existing
`typecheck:functions` gate runs both so test coverage is retained. No production
migration/provider changes or package publication were performed.

## Checkpoint: folder access foundation and admin controls

Implemented locally: explicit existing-account/machine workspace membership;
member/viewer roles and active status; folder edit/view/none defaults with
owner/edit/view/none overrides; admin membership and folder access editors;
optional API credential binding with live folder access intersection. Removing a
member (including Auth-account deletion) deletes bound keys rather than upgrading
them to unrestricted credentials. Workspace viewers remain capped at read.

Verified sessions resolve their membership server-side without app admin roles.
Scoped SQL now applies live access to management, targeting/presentation,
analytics/events and server conversion attribution. Member folder creation grants
creator ownership. Moves require both folders to be editable; member deletion of
a nonempty folder is rejected. Global tag/template mutation stays with workspace
owners. Legacy unbound API credentials retain explicit scope semantics.

The full permissions requirement is still partial: a dedicated member workspace
route, member-aware settings/analytics UI, Ask to edit and owner notifications,
all-source inventory access semantics and native runtime/release proof remain.
Administrators can configure candidate access controls now; non-admin members
have scoped API access but cannot use the admin console. Existing production
schema, memberships, credentials and provider state are unchanged.

Validation: 32 focused API/permission-control tests pass. The complete migrated
SQL suite includes real tracked-click analytics, denied conversion writes after
access removal, policy denial, membership deletion cascades and unchanged legacy
workspace/selected-key semantics. All five native SDKs and examples still pass
through actual loopback HTTP → edge handler → isolated PostgreSQL. Build,
functions types, targeted lint and migration versions pass. App typecheck stays
at 704 inherited errors, none new. Browser screenshots `folder-access-desktop.jpg`
and `folder-access-mobile.jpg` use a local fixture with production fetches
blocked and simulated changes. Saving folder defaults/overrides and the mobile
machine form were verified; mobile scrollWidth=clientWidth=390. Temporary viewport
and tab were cleaned up. See `docs/guides/redirect-folder-access.md` for current
API semantics and explicit remaining permissions work.

## Checkpoint: authenticated member workspace

Implemented locally: `/links-workspace` uses verified membership, separate from
the app admin console. Accessible links are searched/paged with exact scoped
counts. Creation/editing, new-from-existing prefill, six UTM fields/templates,
folder/tag/comment assignment, folder creation/rename/deletion/access, selected
bulk moves/archive/restore/confirmed deletion, CSV import/export of loaded or
selected rows, QR export, behavior settings and analytics use the scoped API.
Viewers can inspect disabled behavior controls; mutations remain server-denied.
Existing admin settings and reports keep their established behavior.

New registered-session discovery and scoped variant-performance endpoints support
the member UI. Folder APIs return effective edit/manage capabilities. Account IDs
partition member, policy, access and analytics caches; account changes remount
the workspace before another account's response arrives. Private route is
noindexed. API/import errors preserve edits and selection for correction/retry.

Ask to edit/owner notifications, invitation/account discovery, all-source
inventory permission semantics and production multi-account verification remain
open. The member workspace currently manages short links; other inventory
sources remain source-managed in the admin inventory. No production schema,
permissions, memberships or credentials have been changed. All other unfinished
requirements in the main ledger remain in scope.

Validation: 99 tests across seven API/page/policy/report/import/access/SEO files
pass. Actual migrated SQL verifies effective folder capabilities (including key
scopes), permitted/denied variant metrics and prior ACL invariants. Five native
SDKs and examples pass through loopback HTTP and migrated SQL. Build, functions
types, targeted lint, formatting and migration version checks pass. App typecheck
remains 704 inherited errors, none new. Native browser proof uses a local fixture
with production fetches blocked: prefilled creation, template replacement,
updated link count, scoped report, and mobile creation dialog. Workspace and
dialog scrollWidth=clientWidth=390. Screenshots are `member-workspace-*` under
`outputs/redirect-dub-parity/`. Temporary viewport and tab were cleaned up.
Production multi-account/provider/release evidence is still outstanding.

## Checkpoint: edit access requests and durable owner notifications

Implemented locally: Ask to edit for view-only folders, optional message, own
status/withdrawal and owner review with explicit editor/owner confirmation.
Current ownership and active membership are checked at decision time; workspace
viewer caps remain intact. Duplicate pending requests do not notify twice;
per-folder/member cooldowns bound new requests. Requests, ACL grants, inbox
notifications and private mail jobs share the same transaction. Editors may now
rename folders; ownership/deletion/access management remain separate capabilities.

A secured scheduled consumer uses the configured Resend provider, stable job
idempotency, leases, bounded retries/backoff and a 23-hour ambiguity window.
Recipient changes, ownership loss and obsolete requests suppress mail. Emails
contain a generic authenticated review link without folder or requester details.
A minimal service-only verified-address definer is necessary: read-only actual
project metadata proves service_role cannot SELECT Auth users; broad Auth-table
access is not granted. Other new functions remain invokers and private.

No production state or real notifications were changed/sent. Read-only checks
found cron/Vault and the invoke secret available, but the project-local Vault URL
missing. Deployment, project URL/provider/sender verification, controlled-account
inbox/email/cron proof, invitation/account discovery and all-source permission
semantics remain open. The full original requirements ledger stays in scope.

Validation: 56 tests across nine request/API/mail/worker/member/settings files
pass. Actual migrated PostgreSQL proves request deduplication, cooldown/actor
limits, paging/privacy, current-owner decisions, workspace-viewer rejection,
editor rename, atomic grants/inbox/mail, retry delays, lease recovery/stale
acknowledgements, idempotency-window limits and recipient suppression. Provider
calls are mocked; worker tests execute the real shared authorization gate and
reject ordinary accounts/user-editable metadata. All five SDKs/examples still
pass through loopback HTTP and migrated SQL. Build, functions types, targeted
lint, formatting and migration checks pass; app types remain 704 inherited
errors, none new.

Native browser proof uses `access-request-*` screenshots under
`outputs/redirect-dub-parity/`: saved request, explicit owner selection/confirmation,
simulated approval and empty review queue, with production fetches blocked.
At 390 pixels the page has no horizontal overflow; the permission select was
constrained to its 324-pixel parent. Temporary viewport/tab were cleaned up.
These are fixture and isolated-database results, not live notifications or grants.


## Checkpoint: saved reports and public aggregate dashboards

Personal saved reports now preserve named filters and dates, with optimistic
updates, loading and cascade deletion. Explicit publication review creates a
separate captured scope. Clicks are public by default; conversion/revenue data
requires opt-in. Password, expiry, revocation and current owner/member permissions
are enforced in SQL and the HTTP handler. Workspace owners can explicitly choose
future matching folder links; ordinary members can share only one editable link.

The public page exposes sanitized aggregates only. Passwords stay out of URLs and
query-cache keys. Revoked/error refreshes remove cached titles and data. The actual
service worker now bypasses these pages and redirect APIs, purges prior managed
cache entries, and preserves unrelated offline data. Response headers additionally
prevent storage/referrer disclosure and search indexing. See
[the saved report guide](../guides/redirect-saved-reports.md) for contracts and limits.

Evidence: migrated PostgreSQL suite, actual HTTP handler with real password hash
verification and revocation, five SDKs/examples, focused UI/API tests, production
build and targeted checks. Native fixture screenshots are `saved-report-published-
desktop.jpg` and `shared-report-{desktop,mobile,revoked-mobile}.jpg` under the existing
outputs directory. The mobile page fits 390 pixels without horizontal overflow.
No production reports, shares or grants were created. Public indexing opt-in,
team report discovery, report SDK methods and production
release remain open alongside the full requirements ledger above.

### Next extension: viewer date selection

Within the approved dashboard parity scope, public viewers can select preset or
custom UTC dates and reset to the captured report dates. Changing a public date
range must never widen a saved start/end boundary or change link, folder, tag,
conversion or private dimension filters. Unbounded published boundaries allow
selection on that side. The server validates ISO instants and positive intervals,
returns only the public date bounds/selection, and performs the same password,
view budget, permission, version, expiry and revocation checks for every read.
Date inputs stay in a bounded POST body with passwords; none enter public URLs.
The existing aggregate grain stays fixed to the published report. Invalid dates
produce an actionable error without displaying stale metrics. This increment
does not settle the separate search-indexing option or production release.


## Checkpoint: viewer-controlled reporting dates

Public dashboards now offer 7/30-day presets, custom UTC instants and reset to the
published dates. The server accepts a closed date-only override object and rejects
widening of either saved boundary. Captured link scope, country/dimension filters,
conversion visibility, current permissions, password budgets, version gates and
revocation all remain enforced. Only date selection/bounds are added to public
metadata; private filters stay private. Invalid date responses remove stale
metrics while preserving a correction/reset control; unavailable dashboards also
remove the date controls.

Evidence: actual migrated PostgreSQL verifies seeded half-open date boundaries,
zero results, unchanged link/country filters, rejected widening/forged filters and
lost access. The real HTTP handler verifies date-only and password-plus-date reads
against that database, alongside all five native SDK/example runs. Fourteen focused
UI/API tests pass, production build and targeted lint pass, and application types
remain 704 inherited errors with none new. Native desktop/mobile fixture checks
confirm 61 → 21 clicks for the preset, a zero custom interval, reset to 61 and
removal on revocation. At 390 pixels client and scroll widths are both 390. The
`shared-report-dates-*` screenshots retain explicit fixture labels. Temporary
browser tab and viewport were cleaned up. No production state was changed.

### Next extension: explicit dashboard indexing

Add an off-by-default publication setting, reviewed before publishing. Password
protection and indexing cannot be combined. Existing publications stay noindex.
The edge must use the live, sanitized public report read (with its existing
budgets/permissions/version/expiry/revocation gates) before emitting indexable
HTML, rather than relying on client-only robots changes or a second metadata API.
Only explicitly indexable, unprotected shares expose their title and aggregate
summary in server HTML. Other shares retain a generic shell and noindex. All
share HTML stays no-store/no-referrer, including failures; localized/query variants
stay noindex. Indexable reports do not get generic locale alternates or unrelated
hub content. Client robots metadata follows the same sanitized flag. Revocation
can stop future publication but cannot immediately remove search-engine copies.


## Checkpoint: explicit search indexing for shared dashboards

Publishing review now includes an off-by-default indexing choice, with a visible
status on each publication. Password entry clears/disables it; API validation
and a database constraint also reject passwords plus indexing. All existing
publications retain noindex. Indexing is a frozen share setting: revoke/re-publish
to change it. No sitemap/token registry is generated.

The edge uses the live sanitized public report endpoint, including current rights,
budgets, expiry and revocation checks. Only a successful explicit opt-in publishes
the escaped title and aggregate summary in server HTML. Both human and crawler
HTML use the same summary and a single robots tag. Other states stay generic and
noindex, including backend failures and error shells. All report HTML remains
no-store/no-referrer. Query/localized variants stay noindex without backend reads;
there are no shared-report hreflang alternates. The browser follows the same flag
and resets robots metadata when a refresh reports revocation. This controls future
publication, not the timing of removal from external search-engine caches.

Evidence: SQL proves defaults, explicit stored/listed/read choice, rejected
password combinations and live revocation. Actual HTTP against migrated PostgreSQL
verifies creation, public flags and rejection/revocation, alongside five SDKs and
examples. The actual middleware runs in native workerd/HTMLRewriter and verifies
robots/headers/body behavior for people/bots, default/protected/revoked/error/rate-
limited states, query/localized variants and 404/500 shells. Eighty-seven focused
UI/API/meta tests pass. Build, functions types, targeted lint/formatting and migration
validation pass; app types remain 704 inherited errors, none new. Native fixture
proof includes default-off, password restriction, explicit review, saved status,
index→noindex on revocation and 390-pixel layout without overflow. Temporary tab
and viewport were cleaned up. No production publication/settings were changed.

### Custom domains: architecture and implementation sequence

Current evidence: managed short URLs and the public resolver use a global slug,
and the Pages relay serves only `/go/:slug`. Existing Cloudflare admin tooling
supports read operations; it is not a SaaS-hostname provisioner. Custom domains
therefore require coordinated registration/ownership, provider TLS/routing,
hostname-scoped slug allocation, resolver/API/SDK and builder/QR/inventory changes.
A TXT proof cannot stand in for working branded routing.

Use a workspace-owned domain registry with private challenges, owner-only settings,
versioned edits and disabled-first lifecycle. Verify exact `_qg-redirect.<hostname>`
TXT challenges via a fixed HTTPS DNS resolver with bounded responses, real DNS
name/type/status checks, attempt budgets and optimistic result application.
Hostnames are normalized to ASCII and reject URLs, IPs, private/reserved suffixes
and the site's own infrastructure. Domain/root/not-found/expiry defaults are
public HTTP(S) destinations, never arbitrary internal URLs. Missing or expired
ownership/provider checks must not imply readiness.

Implement in dependency order: (1) registry, real ownership verifier, owner UI and
stored defaults; (2) durable Cloudflare custom-hostname lifecycle plus TLS/routing
checks and deprovisioning; (3) hostname-scoped slug namespace, public worker/relay,
primary-domain selection and defaults in resolver, CRUD/bulk/SDK, builder/QR and
all-source inventory. DNS controls remain explicit; do not alter existing DNS or
provision paid external resources during local verification. Preserve all phases
in the parity ledger until native provider and controlled-domain evidence exists.


## Checkpoint: private custom-domain registry and ownership checks

The owner workspace now registers multiple domains and presents exact TXT
instructions. The production verifier uses bounded Cloudflare DNS-over-HTTPS
reads, exact name/type/token matching, cooldown and owner/global budgets before
network calls, and single-use/versioned/short-lived result application. Fresh
proof expires after 24 hours; definite loss clears it and transient errors cannot
extend it. Domain settings retain root/not-found/expiry defaults and disabled
state, reject private/looping destinations and prevent orphaning provider records
on removal. Setup panels stay open when a successful action changes versions.
The branded proxy now forwards guarded DELETE bodies.

This is the first prerequisite stage, not working custom-domain routing. The UI
explicitly separates ownership from TLS and serving; it does not emit active
branded URLs or primary choices. The full phase sequence above remains required.
Additional domain archive/transfer/subpath, authorized DNS auto-configuration and
forwardable setup workflows discovered in the current Dub documentation stay in
scope. See [Custom domain setup](../guides/redirect-custom-domains.md).

Evidence: migrated PostgreSQL verifies owner-only access/private grants, unique
challenges, defaults, cooldown, version/nonce/observation races, rotation, expiry,
transient failures, loss/disabled states and provider cleanup guard. Actual HTTP
through the edge handler into that database verifies the DNS flow with an isolated
provider response, including a cooldown before a second DNS call, stale edits,
lost proof, deletion and API-key denial. Five SDKs/examples still pass. Native
`domain-registry-*` screenshots show pending/verified/rotated states, saved defaults
and mobile wrapping at 390 pixels with no horizontal overflow. Browser tab and
viewport were cleaned up. All DNS results/registrations in browser proof are
labelled fixtures; no production DNS, provider or registry state was changed.

### Provider lifecycle design

Use a durable per-domain desired-state job with zone/CNAME-target binding, leased
claims, bounded retries and a recorded create intent before Cloudflare POST. A
preflight exact-hostname lookup rejects silent adoption of existing objects.
GET/DELETE can retry; uncertain POST outcomes enter owner review instead of being
posted again. A late create receipt records the provider object even if the
request was cancelled meanwhile, then queues cleanup. Lease/intent guards prevent
stale status results from activating anything. An explicit reviewed adoption can
reconcile an exact provider candidate after fresh TXT proof for connection (or solely
for cleanup while connection stays disabled after ownership loss); do not depend on
Cloudflare Custom Metadata, which is not available to every account.

Connect requires fresh proof, enabled domain and current owner permission. A
pending connection can be cancelled; a known object is deleted only using its
stored zone/ID after an exact hostname check. A possibly created but unknown
object prevents domain registration removal until reconciliation proves absence
or adopts then disconnects it. Edits/rotation/lost ownership cannot become stale
TLS readiness. Provider status, certificate status, validation records, attempt
state and sanitized failure information are visible to owners. The worker is
internal/admin authorized, configured with dedicated least-privilege provider
secrets, and remains idle when configuration is absent. No provider/DNS writes
are performed in local validation. Public hostname routing/namespaces and actual
controlled-domain deployment remain the following required stage.


## Checkpoint: durable Cloudflare hostname/TLS lifecycle

Dedicated provider configuration now enables reviewed connection, status refresh,
disconnection, existing-object reconciliation and guarded absence confirmation.
The API queues work; an internal/admin worker consumes private leased jobs. Exact
preflight, recorded single-use creation intent and late receipt tracking prevent
blind POST retries and cancellation orphans. A timed-out create enters review.
Cleanup rechecks the exact stored hostname/zone/ID and handles confirmed absence;
unknown creations block registration deletion. Candidate adoption is explicit;
cleanup-only adoption cannot enable readiness. An aged uncertain intent with a
fresh empty lookup can be cleared only after explicit owner absence attestation.
Configuration binding can change only after full disconnection.

Provider activation and certificate status are distinct. Readiness requires fresh
active statuses plus current ownership/enabled/owner/request state, and is closed
immediately by disconnect, role loss or proof invalidation. Healthy polling,
backoff/Retry-After, attempt caps and owner-visible validation/error states are
implemented. Missing config leaves the worker idle. The minute schedule uses the
existing project-local internal invoke mechanism, but no actual schedule/provider
execution or live configuration is claimed here. Public Worker routing, DNS target
and controlled-domain checks, provider validation restart, domain namespaces,
primary selection and all integration/release requirements remain open.

Evidence: migrated PostgreSQL proves intent/lease/operation guards, late receipt
cleanup, uncertainty/review/absence, fresh TLS conditions, configuration binding,
private grants and registry deletion guard. Seventeen focused UI/adapter/real-auth-
worker tests pass. Actual HTTP → edge handler → migrated queue → actual adapter →
isolated Cloudflare API proves one POST, pending vs active TLS, polling and queued
cleanup; all five SDKs/examples retain their tests. Build, functions types, targeted
lint/formatting and migration validation pass; app types remain 704 inherited
errors with none new. Native `domain-provider-*` desktop/mobile screenshots show
review, queued/pending/active certificate states and disconnection. At 390 pixels
client and scroll widths are both 390. Temporary browser tab/viewport were cleaned
up. Provider/DNS state in native tests is explicitly simulated and all production
requests blocked. No production Cloudflare, DNS, registry or deployment writes.

### Hostname namespaces and signed public routing

Add a domain foreign key to managed SHORT links, with uniqueness per domain and a
separate default `/go/` namespace. The built-in resolver must explicitly filter
that namespace, never select an arbitrary same-slug record. Preserve link-ID
scopes, folder permissions, atomic bulk/upsert, policies and attribution.
Store the immutable public hostname alongside each binding for inventory reads;
clients cannot override that derived value. Binding new/moved links requires a
ready domain; edits to an existing unavailable domain can still repair its links.

A dedicated Cloudflare SaaS relay takes hostname/path from its actual request URL,
strips incoming internal headers, and signs method, hostname, path, canonical
query and visitor IP with a domain-separated HMAC. The resolver verifies the
signature and consistency before looking up the domain. Unknown/unready domains
never fall back to the built-in namespace. Current domain/owner/TLS rights are
checked in SQL, including again at click recording. Root/not-found/expired
fallbacks use stored defaults, while previews, passwords, targeting, conversions,
QR attribution and cloaking keep the existing resolver behavior.

An explicit browser GET to the branded health endpoint proves that public DNS/TLS
and the deployed relay reach this backend; only its signed, authorized request
records a routing check tied to the provider ID and protocol. No server-side
fetch to a user-supplied hostname is introduced. Current TLS/ownership plus a
recent matching routing check gates choices/binding/primary. Background provider
checks renew previously verified TXT proofs before expiry, using the same bounded
DNS verifier and current owner authority. Missing proof closes routing. The full
builder, primary, inventory, CSV/QR, five SDK and controlled-deployment integration
requirements remain in scope; managed root-link policies and provider validation
restart also remain explicit follow-up requirements.

Implemented locally: hostname foreign keys and scoped unique indexes, explicit
built-in null namespace, canonical API URLs/domain filters, scoped upsert/bulk,
immutable inventory hostnames, and readiness checks for new/moved bindings.
A dedicated Cloudflare SaaS relay signs actual URL scope and strips untrusted
internal/customer auth headers. The resolver verifies protocol/method/host/path/
query/IP/time, isolates domains without fallback, retains passwords/previews/
cloaking/targeting/conversions/QR attribution, and uses stored domain defaults.
Current authority/ownership/TLS gates resolution and atomic visit recording.
Both older visit/click entry points now delegate to those same guards. A branded
request cannot count against a link moved back into the built-in namespace.

The owner panel runs a bounded, explicit browser health GET with no credentials,
referrer, cache or redirects and refreshes authoritative registry readiness.
Signed health/traffic records proof bound to provider ID/protocol; active traffic
refreshes after six hours, proof expires after 24 hours. Known-provider polling
renews previous ownership proof using existing nonce/version/budget/DNS controls;
rotated or never-verified challenges require explicit initial verification.
Inventory, legacy source display, managed CSV namespace roundtrips/duplicate
checks/template and inventory QR attribution now preserve branded identity.
TypeScript types and the five SDK field contract are documented.

Evidence: all migrated SQL tests pass, including same-slug/default-domain
isolation, spoofed derived hostname, missing/stale routing proof, provider change,
stale TLS, disabled domain, revoked requester, namespace transition and legacy
entry-point guards. Actual owner HTTP → SQL → actual provider adapter exercises
route-proof gating, canonical URLs, scoped list/upsert and background DNS renewal;
all five native SDKs/examples pass. 110 focused tests across 13 files pass,
including actual Worker → resolver execution, MAC tampering, password/preview/QR
behavior, bounded forms, browser health flow, CSV and inventory regressions.
Worker types and local bundle dry run pass. App types remain 704 inherited errors
with none new; functions types, targeted lint/formatting, production build and
2273 unique/parseable migrations pass. Actual CSV → SQL integration also passes.
Native browser verified the owner routing check and responsive controls; mobile
client/scroll width are both 390. Saved local-fixture evidence:
`outputs/redirect-dub-parity/domain-routing-ready-desktop.jpg` and
`domain-routing-ready-mobile.jpg` in the shared workspace root. Temporary tab and
viewport were cleaned up; production requests were blocked in the fixture.

This is a checkpoint, not full Dub parity or a production rollout. Still required:
domain choices/primary preference and full builder/member integration, broader
all-source folder semantics, managed root-link policies, provider validation
restart, remaining domain lifecycle/DNS automation, and every other open feature
in this ledger. Dedicated Worker/zone routing, real DNS/TLS, scheduled renewal,
production migrations, release/PR/push and controlled-domain verification remain
unperformed. No production provider/DNS/database/deployment writes were made.

### Domain choices, primary preference and interactive builders

Use a private versioned singleton workspace preference for the primary hostname.
Only current owner sessions may change it, and choosing a custom primary requires
current ownership, TLS and routing proof. Selecting the built-in domain clears
the preference. This changes interactive creation defaults, never existing links;
the documented API omission behavior remains the built-in namespace.

A links-read endpoint supplies paginated ready public domain IDs/hostnames without
challenge/provider data. Creators see ready workspace domains; credentials bound
to existing IDs and non-creating members see only domains already used by visible
links. Current scope, member activity and folder permissions are checked in SQL.
Return primary availability explicitly so a failed primary never silently changes
the interactive creation URL. Client pagination must detect repeated cursors.

The admin builder and member editor use one shared accessible domain selector,
show the selected canonical URL, submit explicit domain IDs through scoped atomic
link mutations and use the returned shortUrl for QR/export. Existing bindings can
be preserved when a domain becomes unavailable, so repair remains possible; new
or moved bindings still require readiness. Account-keyed queries and current SQL
checks prevent stale client choices granting access. Owner primary controls use
optimistic versions and re-fetch availability; no DNS/provider writes are added.

Implemented locally: private versioned primary preference with owner-only writes,
ready-only public-field domain catalog, scoped/cursor-paginated reads, five native
SDK choice methods, shared accessible selector, tracked-link builder and member
editor domain selection. Builders preserve campaign/prefill/folder/tag fields,
submit explicit bindings through scoped atomic APIs and use canonical returned
URLs. Member list, policy context and QR attribution retain branded identity.
Existing unavailable bindings can be repaired; unavailable primaries or vanished
selected choices never silently appear as a built-in fallback. Preference drafts
retain their editing version across refresh and provide an explicit reload after
conflict. Account-keyed choices detect pagination loops and changing primaries.

Evidence: migrated SQL tests cover private grants, current role/scope revocation,
ready-only fields, creator vs viewer/ID-bound visibility, pagination, stale writes,
disabled primary, explicit clearing and unchanged existing links. Actual HTTP
handler → migrated PostgreSQL proves public-field choices, owner-only primary,
version conflicts, disconnected availability and FK/version clearing on domain
removal. All five SDKs exercise their new choice methods over real local HTTP and
retain their existing management/policy/tracking examples. Fifty-one focused tests
across six files pass, including unavailable-domain repair, disappearing explicit
choices, primary conflicts, canonical builder URLs and paging. A prior report
assertion was updated to include its existing safe allowIndexing=false default.

Native local-fixture browser proof verifies owner primary save → builder default →
preserved campaign/prefill → saved branded URL → generated QR. The actual mobile
screenshot QR decodes to the branded URL plus qg_qr=1. At 390 pixels client and
scroll widths are both 390. Evidence is in shared workspace outputs:
primary-domain-saved-desktop.jpg, domain-builder-primary-mobile.jpg and
domain-builder-saved-qr-mobile.jpg. The preview blocks production requests; its
ready domain/API responses are explicitly simulated. Temporary tab/viewport were
cleaned up. App types remain 704 inherited, none new; functions types, lint,
build and migration validation pass. No production writes or deployments.

Full parity remains open. The legacy raw-table creation form still uses the
built-in domain; domain filter UX, managed root-link policies, provider validation
restart, remaining domain lifecycle/DNS automation and all other unfinished ledger
features remain required, as do controlled real-domain and production release
verification. This checkpoint does not claim full domain/Dub parity or rollout.

### Legacy form completion and full-field atomic saves

Preserve the existing manual form's SHORT/PATH modes, conversions, scheduling,
query settings, visit limits and notes while adding the shared domain selector.
Use an owner-only service RPC/API for its whole raw record so a type/domain change
and policy-expiry synchronization commit together, with fresh owner authority and
current custom-domain binding checks. Do not use an intermediate client save to
convert the type or attach a domain. Path records always clear domain bindings;
new short links use the interactive primary default, while existing unavailable
bindings can still be preserved for repair. Reset the form/choice state between
records. Keep the existing raw row return contract for its caller.

Extend the existing scoped managed-link contract with startsAt, clickLimit and
notes, validated by the shared input helper and persisted in atomic management
mutations. The owner manual endpoint maps the same shared validation plus path/
match-kind constraints, rejects arbitrary row fields and never grants raw record
management to members or keys. Existing link-ID/folder/credential checks continue
for scoped managed-link writes. Verify SHORT/PATH conversions, same-slug custom
namespaces, unavailable bindings, field preservation, expiry synchronization,
role/key denials and rollback on invalid updates through migrated SQL/real HTTP.
