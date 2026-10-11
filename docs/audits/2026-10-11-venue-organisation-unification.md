# Venue and organisation content-type unification

Date: 2026-10-11. Status: production migration and backfill complete; frontend release awaiting CI.

## Scope and evidence

This combines source-code analysis with read-only production schema and coverage
queries. The approved migration is now applied; the bounded production backfill is complete. The checkout contains
substantial unrelated uncommitted changes, which were preserved.

Measured coverage: 97,810 canonical venues, 94,233 unlinked venues, 6,415 canonical
organisations, and 240 organisations with multiple canonical locations.

The CMS registers `venues` and `organizations` independently in
`src/config/contentTypes/index.ts`. Their shared identity fields include name,
slug, description, website identity, logo and tags. The organisation CMS exposes
only a small subset of the organisation schema: it omits roles, contact fields,
claims, lifespan and linked locations.

Venues expose address, city/country, coordinates, category, hours, price,
accessibility, accommodation details, closure and external place identifiers.
Organisations carry roles, legal identity, claims, provenance, editorial copy,
contact/social fields and founding/dissolution information.

The existing relationship is one organisation to many venues:
`venues.organization_id` links to `organizations.id`, while
`organizations.primary_venue_id` optionally selects a primary location.
`useBusinessSpine.ts` already lists linked venues alongside hotels, merchants,
partners, brands and news sources. `useOrganization.ts` exposes venue references,
articles and products for an organisation.

Event content uses `venue_id` for location and `organizer_id` through a venue
resolver. Venue public detail also reads linked organisation identity. Changing
these references requires an explicit migration contract.

The prior approved design in
`docs/plans/2026-07-26-business-spine-unification.md` established organisations as
the identity spine and retained typed detail tables. The new request extends that
model to a single content type; it supersedes the separate CMS experiences.

## Alternatives

1. Rename or combine navigation only. Low effort, but leaves two content types,
   two editors and overlapping identity; does not satisfy the requested merge.
2. One Organisation content type, with roles and nested locations. Recommended:
   one identity, list, editor and publication workflow; location-specific data
   remains representable. Existing venue storage can become an internal detail
   table during migration.
3. Flatten both tables into one row shape. Gives one physical table but either
   duplicates a multi-location organisation or loses individual locations. A
   parent/child structure would be needed to restore those semantics.

## Proposed unified design

- Canonical content type: `organizations`, labelled Organisation/Organisations.
- Reuse the existing multi-valued roles, including venue, organizer, support,
  advocacy, publisher and seller. Role labels and location categories remain
  different concepts: one organisation may have several roles and locations.
- One editor: Identity, Roles, Locations, Contact, Media, Publication and Quality.
  Hours, address, coordinates, accessibility, booking and closure belong to a
  location; legal identity, claims and organisational lifespan belong to its owner.
- Locationless organisations can publish without an address. Venue/location
  validation applies when a location is added, with existing quality requirements
  retained for map and directory eligibility.
- Existing `venues` rows become internal location details, removed as a separately
  registered CMS content type once the unified editor supports their operations.
- Venue submissions resolve to the unified content type with a venue role and a
  location. Support/advocacy/organizer submissions need no fabricated location.
- Keep individual locations addressable for maps, events and location bookmarks.
  A closed venue does not imply that its organisation has dissolved.
- Preserve old public URLs until canonical destinations and redirects are defined.
  Linked organisation and location search results need distinct presentation and
  ranking rules to prevent duplicate identity results while keeping places findable.

## Migration and acceptance requirements

1. Measure linked/unlinked canonical venues, organisation role coverage,
   multi-location organisations, duplicate candidates and dependent references.
2. Adopt existing organisation identity before creating new records. A shared
   domain alone cannot decide which branch location is identical. Ambiguous links
   require review; preserve provenance and existing IDs.
3. Implement unified list/editor and transactional identity/location mutations;
   preserve permissions, revisions, translations, quality gates and lifecycle rules.
4. Backfill missing identities in bounded, resumable batches. Keep an ID mapping
   and migration audit so existing event, image, comment, bookmark, search and
   business references remain resolvable.
5. Switch CMS, submissions, public identity pages, search adapters, metadata,
   sitemaps and redirects together after compatibility checks pass.
6. Verify one-place venues, multi-location operators, locationless support groups,
   dissolved advocacy organisations, closed branches, duplicate slug collisions,
   legacy URLs and write authorization. Confirm backfill idempotence and rollback.

## Implemented

The CMS registers `organizations` as the single content type. The internal venue
configuration remains available to validators and legacy integrations, but is
absent from content-type menus. Old list and editor links resolve to the unified
identity, and legacy queues retain their location workflow targets.

The organisation editor exposes multiple roles, shared identity/contact/media,
publication and quality, plus expandable location forms with their own history
and archive actions. Saves use one PostgreSQL transaction with optimistic
concurrency checks on the identity and changed locations. Claims, quality,
provenance, safety and external identifiers are excluded from writable payloads.

Publication metadata synchronizes the identity's public status, including privacy,
draft, archive and restore. Refreshing a workflow decision preserves pending field
edits and replaces the concurrency timestamp. Location closure does not dissolve
its owner. Public identity APIs omit archived and anonymously safety-gated branches.

Venue and accommodation submissions share the organisation content type while
retaining their established location ingestion target. A locationless organisation
submission has its own identity form and is routed through the existing generic
pipeline with an explicit commit allowlist. The public organisation directory now
includes venue, organiser and community role filters.

New location inserts acquire an identity. The bounded backfill adopts only a unique
name/domain/geography match; ambiguous matches get a separate identity with review
provenance. Deterministic location slug suffixes avoid the legacy mint helper's
20-name collision ceiling. Generated venue-only identities do not duplicate their
location search documents. Existing venue IDs, URLs and references remain intact.

## Rollout

1. Reconcile the repository's unrelated migration-version problems before using
   a broad database push; do not renumber already-applied migrations.
2. Apply `supabase/migrations/99991791725037_unified_organisation_content_type.sql`.
3. With the existing service credentials in the environment, run
   `node scripts/backfill-venue-organisations.mjs` for a read-only coverage check.
4. Drain with `node scripts/backfill-venue-organisations.mjs --run --batch-size 100
   --max-batches 1000`. Each invocation is capped; reruns resume from remaining rows.
   If any batch fails, investigate the error and resume; do not release an incomplete
   organisation inventory.
5. Confirm zero unlinked canonical locations and sample multi-location operators,
   archived branches, safety-gated entries and generated identity search behaviour.
6. Release the frontend and changed community-submission/commit functions and submit
   worker together. Verify the CMS and public flows on production after deployment.

## Verification

- PostgreSQL 17: compiled the migration against an isolated fixture using live
  organisation/venue column definitions, CHECK constraints and workflow enums. Executed the
  rollback-only regression test covering addressless identities, multiple branches,
  protected fields, cross-owner writes, stale edits, ISO2 normalization, public
  archival, safety, repeatable/capped backfill, common names and workflow visibility.
  External ingestion/audit triggers and PostGIS operations were not replayed; this
  is a focused SQL test, not a full production-schema integration test.
- Production build passes; typecheck passes the existing baseline ratchet.
- 71 focused editor, registry, submission, legacy-link and workflow tests pass.
- Desktop (1366px) and mobile (390px) editor fixtures render with no page errors or
  horizontal overflow. Fixed the mobile sidebar squeezing the main form out of view.
- All migration files pass PostgreSQL syntax/parenthesis checks.
- Broader existing checks found unrelated milestone fields missing from the generated
  schema and an event-quality queue/route role mismatch. The repository-wide migration
  version check also fails on unrelated older migrations and sibling version collisions;
  this migration was allocated by the repository's allocator and is not among those
  reported conflicts.

## Production rollout progress

- Isolated release branch starts from current production/main; unrelated workspace
  edits were excluded. Its targeted app suite passes 184 tests, and the 20 submit
  worker tests pass. The full Deno suite passes 1,644 tests (7 skipped).
- Applied `99991791725037_unified_organisation_content_type` through the Supabase
  CLI; a subsequent dry run confirms migration history is aligned.
- A rollback-only smoke test exercised the real production triggers and validated
  nested saves, stale-save rejection, publication, privacy and archive.
- Live policy preflight preserved authenticated owner venue creation through a
  private trigger-only core. Unreviewed owner and pending venue identities remain
  drafts; public editor resolution retains its elevated-role check.
- Deployed `source-community-submissions` and `pipeline-commit`, plus submit worker
  version `5a1f275a-2b0f-4eee-90c9-0e5160be49ce`.
- Backfill is complete: all 96,902 canonical venues are linked, with zero unlinked
  records. 246 organisations own multiple locations. REST timeouts roll back their
  batch; the script now
  reduces the batch size automatically and resumes from still-unlinked locations.
- Removed 93,318 generated venue-only identity queue entries that the indexer
  deliberately ignores. Confirmed zero duplicate generated identity search documents,
  no venue quality-score drift in the index, and no organisation-reference dependency
  in the venue indexer. The existing search drain continues with zero recent failures.
- The live critical data-quality gates pass. Frontend deployment awaits the remaining
  CI checks in PR #4311. Existing venue IDs and public
  location URLs remain intact.

A physical table collapse is outside the approved design.

Full-suite integration follow-up: legacy route aliases remain explicitly supported;
internal venue details remain revisioned and retain the Locations deduplication lane.
The editor fixture now provides the query context used by real application routes.
All 29 tests covering the seven full-suite failures now pass. The production
migration recovery on main was reconciled without changing applied SQL.
