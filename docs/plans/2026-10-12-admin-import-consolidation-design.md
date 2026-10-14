# Admin import consolidation

The user reported broken imports and overlapping entry points for manual imports, pipeline sources, and email ingestions.

Use Pipelines → Sources as the canonical workspace. Keep the source registry as its default view and add Manual imports and Email history as lazy subsections. Preserve `/admin/imports/data`, `/admin/imports/email-ingestions`, and `/admin/ingestion-rules` as redirects to their matching subsections. Remove the separate sidebar entries and page wrappers. Keep the Pipelines admin gate; Automations retains its moderator gate and leads the Data section so its breadcrumb stays accessible to that section's users.

Manual imports retain URL, CSV, venue-provider, Ticketmaster, personality, and marketplace tools. Flatten redundant section cards and use subsection headings so the Pipelines page has one h1. Remove Eventbrite search from the launcher: the backend documents its retired endpoint and returns a skipped response. Explain the URL/CSV alternatives in the Events section.

Source and email fetch failures must be visible and retryable. Backend application errors and boolean skipped results must never produce a success notification. TripAdvisor's numeric `skipped` field is a duplicate count, so only `skipped === true` means a skipped invocation.

Validation: focused navigation, deep-link, email retry, source load failure, and retired endpoint tests; existing navigation/archetype contracts; typecheck ratchet; lint; production build; rendered desktop/mobile inspection. No database migration is required.
