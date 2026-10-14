# Redirect workspace resource API

Base: `https://queer.guide/api/redirects`; JSON bodies; bearer server credentials
or verified admin sessions. `/folders`, `/tags`, `/templates` support GET list and
POST create. `/:uuid` supports GET detail, PATCH supplied fields and DELETE.
Create returns 201 and a resource object; updates/details return 200 and that object;
delete returns `{id,deleted:true}`. Missing resources are 404. Names are unique
ignoring surrounding whitespace and case; collisions are 409.

Use `workspace:read` to read and `workspace:write` to mutate. They do not implicitly
grant link destinations, private analytics, conversion writes or token management.
Only unrestricted credentials can have workspace permissions. The creation UI/API
reject incompatible selected-link scopes, and SQL also rechecks this restriction
along with revocation/expiry. Every public Data API/RPC path remains private.

List uses `limit` (1–100, default50), UUID `cursor`, ascending UUID order and returns
`{count,data,nextCursor}`. Count is for the complete resource table. Follow the cursor
until null. Resources are shared workspace data; list pages reflect current state,
not a frozen snapshot. SDKs expose page controls for all three resource types.

| Resource | Fields |
| --- | --- |
| folders | name (required on create; trimmed1–100), description (string≤2,000; default empty) |
| tags | name, color (gray/red/orange/yellow/green/blue/purple/pink; default gray) |
| templates | name, parameters (object of campaign source/medium/campaign/term/content/ref strings; default empty) |

Fields are closed to unknown properties. Null name/description/color/parameters,
arrays instead of maps and password/control query keys are rejected. Template
parameter keys use `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`,
`utm_content`, `ref`. Body limits are 64 KiB; query maps use ≤100 entries, key≤200
and value≤2,000 characters. PATCH preserves fields it omits.

Deleting a folder clears its assignments, deleting a tag removes its assignments,
and deleting a template removes the saved definition. Existing links/destinations
remain. Bulk link assignment is handled through `/links/bulk` update operations;
resource creation/renaming uses these workspace routes. Folder member RBAC is still
a separate outstanding requirement and is not claimed by these admin/API permissions.

Verification: isolated SQL tests exercise creation/detail/list/partial updates,
FK behavior, selected-scope/revoked/read-only key denial and RPC privacy. Five SDKs
execute these real routes over local HTTP into the actual edge handler/database.
Production deployment and provider configuration remain unverified.
