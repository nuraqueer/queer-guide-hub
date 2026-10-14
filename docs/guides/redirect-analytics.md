# Redirect analytics

Local candidate on `feature/redirects-dub-parity`; production deployment is not
verified. Open **Analytics** on the Redirects index, or **Detailed analytics** on
a managed link. The existing visit/cohort report remains available separately.

The analytics report filters by event occurrence date in UTC. Choose a managed
link, folder, tag, country, city, device, browser, operating system, hostname,
referrer host, experiment variant, event kind, or QR/link source. Date endpoints
in the UI are inclusive; the API uses an exclusive end timestamp. Presets cover
7/30/90 calendar dates, custom dates and all recorded dates. Choose hour/day/week/
month buckets; zero-activity buckets are retained. Large intervals are bounded
to 2,000 buckets and return an instruction to select a larger interval.

Click metadata comes from bounded user-agent classification and Cloudflare's
network-derived city/region/continent data passed by the branded proxy. Browser
and OS are families, not guessed versions. Missing historical metadata remains
Unknown. Bot classification is heuristic; the control says “detected bots” and
can include them. Location is approximate network metadata, not physical address
verification. Conversion dimensions are inherited from the attributed click.

New managed QR exports append `qg_qr=1` to the encoded short URL. The resolver
records this as a QR-source flag, removes it before the destination URL and query
storage, and keeps unrelated parameters/fragments. External/static QR payloads
are unchanged. Previously printed QR codes without this marker remain link visits.

PostgreSQL aggregates totals, revenue, dimensions and time series in one report
statement. Revenue is returned as exact decimal text and kept separate by
currency. Event activity uses descending receipt-time/ID keyset pagination and a
receipt cutoff, rather than loading the entire history into the browser. Live
updates are an explicit five-second foreground poll. Refresh obtains a new
report cutoff. CSV export follows every matching event page and does not download
a partial result after a read failure. Spreadsheet formula prefixes are escaped.

Reports/views use invoker privileges and underlying RLS. Ordinary users see no
private rows. Activity exposes normalized dimensions, event/customer IDs and
exact amounts; it excludes raw query strings, raw user agents, IP hashes,
destination URLs and password fields. Referrers are hostname-only, with userinfo,
ports and URL queries removed. CSV is a private admin/read-credential export,
not a public sharing endpoint.

## Read API

Create a server credential with **Read analytics and private event activity**.
It can be read-only, write-only, or both; selected-link restrictions apply to
both analytics and activity and are intersected with requested filters.

Use `Authorization: Bearer <credential>` with:

- `GET https://queer.guide/api/redirects/analytics?filters=<JSON>`
- `GET https://queer.guide/api/redirects/events?filters=<JSON>&limit=50`

URL-encode the JSON. Filters: `linkIds`, `folderId`, `tagId`, `start`, `end`,
`event` (`all`, `click`, `lead`, `sale`), `country`, `city`, `device`, `browser`,
`os`, `domain`, `referrer`, `variant`, `excludeBots`, `qr`, `interval`.

Event pages return `snapshot` and `nextCursor`. Pass the same snapshot and the
URL-encoded cursor JSON in `cursor` to continue. Page limits are 1–100. Summary
breakdowns are capped at their top 100 labels; the UI shows top 10. Filter directly
to investigate labels outside those lists. Signed admin sessions can also read;
registered member sessions are restricted to their current workspace access, and
write-only credentials cannot use these endpoints. POST filter bodies are also
supported. Personal saved reports and reviewed public aggregate publications are
described in [Saved reports](redirect-saved-reports.md).

## Evidence and remaining scope

`test:redirect-sql` covers real report calls, zero UTC buckets, dimensions,
folder/tag scopes, keyset paging, exact revenue, private-field exclusion, scoped
link intersections and ordinary-user RLS. Focused tests cover visitor families,
QR URL behavior, date/CSV contracts, API permissions, resolver metadata and UI
filters/live control. Native Stripe regression remains in `test:redirect-stripe`.
Desktop/mobile screenshots use labelled preview fixtures, not production data.

Saved reports and scoped public dashboards are implemented locally with release
verification pending. Customer identity enrichment, outgoing webhooks, domain/
deep-link configuration and provider integrations remain separate parity work.
Reports do not provide strict immutable database snapshots across requests.

References: [Cloudflare request metadata](https://developers.cloudflare.com/workers/runtime-apis/request/),
[Dub analytics API](https://dub.co/docs/api-reference/analytics/retrieve).
