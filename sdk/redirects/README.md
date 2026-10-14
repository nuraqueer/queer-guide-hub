# Redirects server SDKs

Local SDK sources for TypeScript, Python, Go, Ruby and PHP. Each client targets
queer.guide's Redirects API contract; these are not Dub SDK aliases. They cover
managed link CRUD/upsert/count/list/bulk, folder/tag/template CRUD/list, private
analytics and event pages, lead/sale tracking, and presentation/image-upload methods. Link iterators follow keyset
pages and reject repeated cursors. Resource and event pages expose their cursors
for explicit iteration.

Use server credentials from **API and conversion setup**. Scopes are independent:
`links:read`, `links:write`, `workspace:read`, `workspace:write`, `events:read`,
`conversions:write`. Workspace scopes require unrestricted credentials; keys limited
to selected link IDs cannot change or read shared resources. Keep credentials in
server environment variables. No SDK performs token creation or privilege changes.

Clients use HTTPS by default (`https://queer.guide/api/redirects`), reject credentials
in base URLs, and allow plain HTTP only on loopback for development. Requests have
10-second transport timeouts, refuse redirects and cap responses at 8 MiB. Go additionally
accepts request contexts; TypeScript's generic request accepts an AbortSignal.
HTTP failures raise API errors carrying status and Retry-After. There are no
automatic retries, especially for create/update/delete. Retry conversion ingestion
with a stable event ID; pass money as decimal strings to preserve all six supported
decimal places. Revenue responses remain exact strings by currency.

## Local usage

These sources have not been published to package registries. Copy the relevant
source into server code or use the local package/module. No third-party runtime
libraries are required. TypeScript compilation uses the repository's TypeScript.

| Language | Source | Minimum runtime | Example command (from repository root) |
| --- | --- | --- | --- |
| TypeScript/JavaScript | `typescript/index.ts` | Node 22+ | `npx tsc -p sdk/redirects/typescript/tsconfig.json` then `node sdk/redirects/typescript/example.mjs` |
| Python | `python/redirects.py` | Python 3.8+ | `python3 sdk/redirects/python/example.py` |
| Go | `go/redirects.go` | Go 1.23+ | From `sdk/redirects/go`: `go run ./cmd/example` |
| Ruby | `ruby/redirects.rb` | Ruby 2.6+ | `ruby sdk/redirects/ruby/example.rb` |
| PHP | `php/RedirectsClient.php` | PHP 8.1+, HTTPS streams | `php sdk/redirects/php/example.php` |

Set `REDIRECT_API_TOKEN` and optionally `REDIRECT_API_BASE` and `REDIRECT_TARGET`.
Each example creates a random short link and prints its short URL. To exercise
tracking, supply an existing recorded `REDIRECT_CLICK_ID`, `REDIRECT_CUSTOMER_ID`
and stable `REDIRECT_EVENT_ID`. Optional `REDIRECT_AMOUNT` plus `REDIRECT_CURRENCY`
sends a sale; its event ID appends `:sale` to the supplied lead event ID. Creation
needs workspace-wide `links:write`; tracking also needs `conversions:write`.

Python example in server code:

```python
from redirects import RedirectsClient
client = RedirectsClient(token)
link = client.create_link({"target": "https://example.com/register"})["link"]
for record in client.iterate_links({"isEnabled": True}):
    print(record["shortUrl"])
client.track_sale({"clickId": click_id, "customerExternalId": customer_id,
                   "eventId": invoice_id, "amount": "49.900001", "currency": "CHF"})
```

Equivalent method names follow each language's conventions (`createLink` / `CreateLink`
/ `create_link`). `request` / `Request` exposes the owned API path for additional
supported endpoints. See `docs/guides/redirect-link-management-api.md` and
`docs/guides/redirect-workspace-api.md` for fields, permissions and semantics.

## Verification

`npm run test:redirect-sdks` starts a loopback HTTP server, loads the actual edge
handler and uses the real migrations in isolated PGlite PostgreSQL. It runs all
five native runtimes, creates and edits shared resources and assigned links,
updates/upserts/deletes, writes lead/sale events with deduplicated retries, reads
analytics/events, follows a 101-row paged list, refuses redirects and preserves
429 retry headers without automatic retries. Final SQL checks prove five leads,
five sales and exact `249.500005` total. All five runnable examples are then
executed against that same isolated API with tracked leads/sales, producing a
verified ten-sale total of `254.500010`. No production API, credentials, payment
provider or schema is touched.

Go must be available on PATH or configured via `REDIRECT_GO_BIN`; the local agent's
verified vendor runtime was kept under ignored `tmp/go-runtime`. The test command
does not download runtimes. Production migrations/release, package publication,
policy/domain/deep-link fields, webhooks and external integrations remain pending.

Presentation APIs are documented in `docs/guides/redirect-presentations.md`.
The SDK integration suite checks all five presentation/upload wrappers with real
encoded raster bytes; file storage uses a fixture adapter.


Policy management is available through getPolicy/updatePolicy (TypeScript/PHP),
get_policy/update_policy (Python/Ruby), and GetPolicy/UpdatePolicy (Go). Use
links:read for reads and links:write for patches. The response exposes policy and
hasPassword only; top-level null policy fields remove a setting, and password:null
removes protection. See [the policy API guide](../../docs/guides/redirect-policy-api.md)
for fields, complete examples, hash limits and expiry/merge semantics.

## Branded hostname namespaces

Pass `domainId` (a registered domain UUID) in link create/upsert/update or bulk
input. Pass `null` to select the built-in `/go/` namespace. Omitted updates preserve
the current binding; omitted create/upsert selects the built-in namespace. The
same slug can exist on different domains. List/count filters accept the same
UUID/null `domainId`. Responses include the canonical `shortUrl`, `domainId` and
`domainHostname`; use `shortUrl` instead of constructing a URL from the slug.

A new or moved binding requires current ownership, TLS and signed public-routing
proof. Existing folder/member/token permissions still apply. Domain registration,
provider setup and routing checks are owner-session controls; these SDKs do not
acquire those privileges. Python/Ruby/PHP dictionaries and Go `Object` pass the
same fields as TypeScript `LinkInput`. The implementation and SDKs remain local
sources awaiting production rollout/publication.
