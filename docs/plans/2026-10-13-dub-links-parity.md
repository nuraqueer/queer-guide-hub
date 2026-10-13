# Redirects: Dub Links feature parity

Objective: analyze https://dub.co/links and implement the same capabilities in
Redirects. This ledger preserves the full scope. A feature is complete only
after schema, server behavior, UI/API, tests, and applicable runtime evidence
exist. Existing local tools are a foundation, not proof of parity or deployment.

## Requirements and evidence ledger

| Requirement | Required behavior / evidence | Current state |
| --- | --- | --- |
| Branded links | Custom slug, random slug, editable destination; shorten arbitrary public HTTP(S) URLs | Partial: own-site links only |
| UTM builder | Source/medium/campaign/term/content/referral; preserve queries/fragments | Partial: referral absent |
| Shared UTM templates | Named workspace templates, apply/save/edit/delete in builder/settings | In progress |
| Folders | Create/rename/delete/move links, folder-filtered list and analytics | In progress |
| Tags | Multiple colored tags, create/rename/delete, shareable filtered list and analytics | In progress |
| Comments | Team-visible comment on link card, clickable hyperlinks | In progress |
| Folder permissions | Explicit view/edit permissions for team members, enforced in database/API | Missing |
| Bulk actions | Create/update/upsert/delete, folder/tag assignment, archive, import/export, QR export | Partial: CSV import and basic export |
| Custom previews | Uploaded OG image (1200×630, ≤1.5 MB), title≤120, description≤240, video API, crawler unfurl | Missing |
| AI previews | Generate title/description from destination content using configured AI provider | Missing |
| Custom domains | Verify ownership/DNS, multiple domains, primary domain, redirects on branded hostname | Missing |
| Domain defaults | Root/not-found redirects, default expiration URL, workspace/domain QR logos | Missing |
| Deep links | iOS/Android association files, app page routes, fallback and deferred attribution | Missing |
| Geo targeting | Country-specific destinations and default fallback | Missing |
| Device targeting | iOS/Android destinations, evaluated before geo | Missing |
| A/B testing | 2–5 destinations, weighted traffic≥10%, end date≤6 weeks, manual winner/end | Missing |
| A/B completion | Device→geo→experiment priority; choose winner by sales/conversions, rates, clicks; leads fallback | Missing |
| Password links | Password challenge, hashed secret, no disclosure/bypass, scoped access | Missing |
| Expiration | Date and expired destination URL, live enforcement without stale cached rules | Partial: date and 404 only |
| Link cloaking | Explicit iframe mode with accurate iframe limitations, standard redirect fallback | Missing |
| Branded QR | Dots square/circle/joined; marker center square/circle; border square/rounded/circle; colors | Partial: square monochrome |
| QR logos/export | Workspace/domain/logo precedence and hide; SVG/PNG/JPG; clipboard image and image URL | Partial: PNG/SVG and link copy |
| Click analytics | Real-time totals/time series, custom date/filter/export, countries/cities/devices/browsers/OS/referrers | Partial: visits/date/country/host |
| Conversion tracking | Click attribution, leads/signup/sale/revenue, trusted conversion ingestion and application hooks | Missing |
| Customer insights | Customer journey across click→lead→sale with private event timeline | Missing |
| Live events | Paginated live click/lead/sale stream, real events rather than demo data | Partial: recent clicks |
| Shared dashboards | Revocable scoped sharing, sanitized aggregate-only default | Missing |
| Custom reports | Custom dates, granular link/folder/tag/domain/geo/device/event filters | Missing |
| Integrations | Segment and GTM adapters; native configured integrations and provider callbacks | Missing |
| REST API | Authenticated/scoped link CRUD/upsert/count/list, analytics/events, folders/tags, bulk operations | Missing |
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
