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

## Implementation and validation

All five tabs use the CMS list controls and table renderer. Operational lists
use stable view IDs and source adapters; generic inline edits and mutations
are disabled, with actions delegated to existing protected handlers. Hotel
bulk edits retain the original field whitelist. Selected operational records
can be exported without introducing bulk writes. Existing editor saves refresh
the lists, and changing tabs clears foreign saved-view IDs.

Desktop/mobile inspection of all five lists confirmed no document overflow.
A single correction batch unified mobile header stacking, reduced default
merchant metrics, removed duplicate brand publication columns and kept row
actions sticky during horizontal scrolling. Confirmation passed. The design
detector reported no findings. Focused list/source/claim tests passed; no new
TypeScript errors were introduced. Temporary example-data previews are not
part of the shipped artifact.
