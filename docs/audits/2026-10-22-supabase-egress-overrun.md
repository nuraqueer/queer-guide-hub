# Supabase egress overrun — 2026-10-20/21

Project `xqeacpakadqfxjxjcewc`, org plan **Pro with spend cap** → quota 250 GB
uncached + 250 GB cached egress per billing cycle. From ~2026-10-20 22:00 UTC
to ~05:00 UTC the gateway answered every edge-function call with
`exceed_egress_quota`.

## How this was measured, and its limit

Supabase `edge_logs` carry `content_length` only for non-chunked responses.
Storage objects have it; most PostgREST responses (gzip, chunked) do not — the
Supabase docs say as much ("these logs currently do not include response byte
data"). So:

- **Storage** bytes are read straight from the logs.
- **PostgREST** bytes are estimated: the top GET URLs by daily count were
  replayed with the anon key and their gzipped size multiplied by the count.
  Whether Supabase bills compressed or uncompressed bytes is not documented;
  both are given. The billing page (`/dashboard/org/_/usage`) is the only exact
  source and was not reachable from this session.

## Top 5 contributors (sample day 2026-10-10, one full day)

| # | Source | Calls/day | Per call (raw / gz) | ≈ GB/day (gz) | Caller |
|---|---|---|---|---|---|
| 1 | Storage `village-images` + `city-images` + `marketplace-images` (direct object downloads) | ~25k | 0.3–4 MB | **~3.9** (2026-10-10), ~0.8 (10-20) | on 10-20 ~78% from Microsoft ASNs: the a11y scanner (by UA) plus desktop-Chrome UAs that are most likely Playwright CI; rest browsers/Meta crawler |
| 2 | `unified_tags?select=*` (venue filters) + paginated full tag list | ~2.1k + ~4.8k | 2.85 MB / 645 KB; 443 KB / 142 KB | 1.35 + 0.68 | browsers — **fixed by #4549** (select trimmed) |
| 3 | `cities?select=*&limit=500` (/map city layer) | ~550 | 5.6 MB / 1.83 MB | **1.0** | browsers — **fixed here** (→ 29 KB) |
| 4 | `countries` rights lists (/travel, /rights/sources, /rights) | ~2.3k | 1.2–1.7 MB / 0.5 MB | **1.2** | browsers — narrow list **fixed here** (→ 12 KB) |
| 5 | `news_sources` list + unfiltered `news_articles limit=200` + 10 category-count HEADs, fired on every city/country page | ~4.4k + ~4.8k | 290 KB / 111 KB; 237 KB / 84 KB | 0.9 | browsers — **fixed here** |

Also large: `queer_villages?select=*` (0.49 GB/day, fixed by #4549) and
`tag_category_assignments` paginated 10×1000 (0.25 GB/day).

Rough total on 2026-10-10: **~10 GB/day gzipped (~25 GB/day if billed
uncompressed)**. Over a 30-day cycle that is 300–750 GB — consistent with
crossing 250 GB late in the cycle. REST request volume fell from 2.88 M/day
(10-10) to ~1.5 M/day (10-20), so the cycle total was front-loaded.

## Who is calling

On 2026-10-20 (1.5 M REST calls):

- **~36% Microsoft ASNs, mostly GitHub Actions**: PR-time a11y scans and Playwright
  e2e build the app locally but read **prod** Supabase. 39 a11y PR runs in that
  day; the scanner alone made 92k Supabase calls and pulled ~270 MB of Storage
  images (every viewport/theme variant is a fresh browser context, so nothing is
  cached).
- **~20% one scraper farm**: `ACEVILLE PTE.LTD.`, 1,537 IPs, headless Chrome,
  ~38k full page renders/day. This is not a code problem — a Cloudflare WAF /
  bot rule on queer.guide stops it before any Supabase call is made.
- **One signed-in user** (`dfec8c70…`) made 171k `user_roles` reads on 10-10
  (17.5k on 10-20) — a polling loop or a long-lived CI storage state. Tiny
  payloads, so negligible egress, but worth finding.
- Edge functions (`Deno` UA, service key) ~150k calls/day, almost all small
  writes — not an egress driver. Function responses: ~4 MB/day.
- Not a cause: `scripts/ci/db-snapshot.sh` (pg_dump through the pooler, counts
  as Shared Pooler egress) merged 2026-10-22, after the incident. It will add
  egress from now on and should be watched.

## Fixes in this PR

1. `/map` city + country layers select only the columns the pins render
   (`usePlaces` gained a `columns` option; default stays `*`).
   cities 1.83 MB → 29 KB gz per call.
2. `/travel` + `/rights/sources` read 4 keys of `lgbti_criminalization` via
   JSON-path selects instead of the 5 KB/country jsonb. 1.24 MB raw → 12 KB gz.
   Verified the four safety helpers (`hasAnyCriminalizationSignal`,
   `hasDeathPenalty`, `deathPenaltyRisk`, `isCriminalized`) return identical
   results for all 250 countries.
3. `useNews({ autoload: false })` on city/country pages: drops the unfiltered
   200-article list, all sources, all categories and ~11 count queries per page
   view (and a race where the unfiltered list could overwrite the filtered one).
   `news_sources` list no longer ships `description` (~40% of it).
4. a11y axe scanner stubs Supabase Storage image bytes with a 1×1 PNG.

Estimated saving with #4549: **~4–5 GB/day gzipped** of PostgREST egress plus
~0.3 GB/day of Storage.

## Recommended next (not in this PR)

- **Cloudflare WAF rule** for the ACEVILLE ASN / headless-Chrome signature
  (dashboard change; ~20% of REST calls).
- Point PR-time e2e and a11y at the local Supabase that #4558 now builds for
  Critical paths, instead of prod.
- Serve `village-images` / `city-images` through R2 (img.queer.guide) — they
  are the biggest single Storage line and the platform convention already says
  images belong on R2.
- Add a Supabase usage check (Management API `/v1/organizations/{slug}/usage`
  or the dashboard) to the nightly health script so a burn rate above
  ~8 GB/day warns before the cap does.
