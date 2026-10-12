# Places editorial in Governance

Approved by the user on 12 October 2026.

Add Places editorial as a fifth Governance mode at
`/admin/governance?mode=editorial`. Reuse the existing editorial component,
including its Hooks queue, generation, review, publication, and Covers tools.
Keep the existing Governance mode switcher and visual conventions.

Redirect `/admin/places-editorial` to the editorial mode, preserving query
parameters and replacing the history entry. Remove the separate Content sidebar
entry; Governance becomes the single navigation destination. Update editorial
metadata to the canonical Governance route. Switching modes clears parameters
owned by other modes using the existing cleanup rules.

Use the current origin/main baseline, which already contains Governance, in an
isolated checkout. The primary local checkout predates Governance and contains
unrelated changes. Verify mode rendering, switching, real legacy redirects,
navigation, lint, and TypeScript checks.
