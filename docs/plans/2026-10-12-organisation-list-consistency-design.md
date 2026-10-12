# Organisation list consistency

Approved by the user on 2026-10-12.

Use one shared list presentation across Directory, Hotels, Merchants, Brands
and Partners in the Organisation workspace. Preserve the incumbent paper/ink
admin design, existing Directory layouts, and all protected editing, syncing
and ownership-review workflows.

Every tab shares saved views, search, filters, sort, column settings, record
count, Add action, table density, status treatment, row action menu, pagination
and loading/empty/error states. Entity-specific columns and actions remain.
Merchants and Partners become tables; detailed merchant metrics and partner
configuration stay in their existing detail/editor surfaces.

Brands defaults to all brands, with ownership-review filters. Ownership review
opens the evidence workflow and retains sensitive-claim confirmations.
Directory extra layouts remain available; operational tabs default to tables.
Preserve organisation scoping when the same managers appear inside editors.

Use existing query and mutation contracts behind the common list UI. Avoid
introducing generic writes to privileged merchant, partner or brand fields.
Verify all five tabs in one desktop/mobile inspection, fix that batch, then
confirm once. Run focused interaction tests plus required repository checks.
