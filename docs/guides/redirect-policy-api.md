# Scoped link policy API

Use `GET /api/redirects/links/{id}/policy` with `links:read`, and
`PATCH /api/redirects/links/{id}/policy` with `links:write`. A verified admin
session is also accepted. Credentials scoped to selected managed short links
cannot read or change policies on other links. The database rechecks current
permissions, expiry and revocation when the request executes.

GET and PATCH return `{ "policy": { ... }, "hasPassword": false }`. Password
plaintext, salts and hashes are excluded. The policy's field names match the
existing policy editor: `preview`, `cloaked`, `track_conversions`,
`device_targets`, `geo_targets`, `experiment`, `expires_at`, and `expired_target`.
Domain and deep-link configuration are still separate unfinished parity work.

PATCH accepts `policy` and/or `password`:

```json
{
  "policy": {
    "track_conversions": true,
    "device_targets": { "ios": "/events/ios", "android": "/events/android" },
    "geo_targets": { "CH": "/events/switzerland" }
  }
}
```

Only supplied top-level policy fields change. Omitted fields and passwords are
preserved, and unrelated concurrent policy patches merge under a redirect-row
lock. Nested objects (including preview, device/country maps, and experiment)
replace that whole setting. Send a top-level setting as `null` to remove it:

```json
{ "policy": { "geo_targets": null, "experiment": null } }
```

`expires_at` is synchronized with the main link's expiration; omitting it
preserves an existing expiration, while `null` clears it. Framed links require
HTTPS or site-relative destinations, including existing targeting rules. The
merged database guard rejects enabling framing over an existing HTTP rule.
A/B experiments require the complete 2–5 variant object, unique IDs, integer
weights of at least 10% totaling 100%, and a duration no longer than six weeks.
Malformed nested objects and unknown fields are rejected before writes.

Set `password` to a string of 1–256 characters to replace protection, or `null`
to remove it. Requests are authenticated and scoped before password work. The
server hashes using the existing salted PBKDF2-SHA256 routine (600,000 iterations)
and never stores the plaintext. Password-hash reservations are limited to
20/link/hour, 20/credential-or-admin/hour and 100/workspace/hour; failed hashing
attempts consume reservations. A 429 includes `Retry-After`, preserved through
the branded proxy. Clearing a password does not require expensive hashing.
Revocation between reservation and mutation prevents the write.

```json
{ "password": "replace-with-your-password" }
```

```json
{ "password": null }
```

The request body is bounded to 64 KB. A patch is atomic: a validation/database
failure does not partially alter password, targeting or expiration. Empty requests
are rejected. All supported policy writers lock the redirect row before updating
its policy, including the existing admin save endpoint. SQL functions are invoker
functions granted only to `service_role`; callers use the authenticated edge API.

## SDK methods

| Client | Read | Patch |
| --- | --- | --- |
| TypeScript | `getPolicy(id)` | `updatePolicy(id, data)` |
| Python | `get_policy(id)` | `update_policy(id, data)` |
| Go | `GetPolicy(ctx, id)` | `UpdatePolicy(ctx, id, data)` |
| Ruby | `get_policy(id)` | `update_policy(id, data)` |
| PHP | `getPolicy(id)` | `updatePolicy(id, data)` |

The TypeScript client exports `LinkPolicy`, `PolicyUpdate` (top-level nullable
patch fields) and `PolicyResponse`. SDKs remain server clients; keep credentials
out of browser code. Existing transport timeout/error/no-redirect behavior applies.

Local evidence includes scoped SQL authorization/rollback/removal/rate-budget
checks, actual handler tests, and all five native clients using live loopback HTTP
against the real edge source and migrated isolated database. Their tests set and
clear passwords, verify persisted hashes using the real password verifier,
check that presentation/tracking survives unrelated patches, and confirm hashes
are absent from API responses. Production migration, endpoint release and SDK
publication remain outstanding.

The current [Supabase database-function guidance](https://supabase.com/docs/guides/database/functions)
and changelog were reviewed. This migration does not use the extensions/operators
affected by the [September PostgreSQL upgrade notice](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes).
