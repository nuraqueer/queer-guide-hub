# News Sources and publisher organisations

Approved by the user on 2026-10-13.

Organisation stores shared publisher identity (name, logo, website, contact details and Publisher role). A news source stores each RSS/API/podcast feed and its ingestion settings. Reuse the existing news_sources.organization_id foreign key: one organisation can own multiple feeds; articles remain connected through source_id, and byline authors remain independent.

Add an admin News Sources workspace with paginated search, status and unlinked filters, publisher, article counts, last fetch and ingestion errors. Use one source form and table across the standalone page, existing Pipelines surface, and a virtual News Sources field in the Organisation editor. Source edit controls cover feed configuration and activation; fetch status and errors are read-only pipeline outputs. Linking requires an existing non-merged publisher organisation. Domain suggestions are reviewable, never automatic; aggregators may remain unlinked. Source names remain feed labels rather than copies of publisher identity.

Provide a publisher picker, organisation edit links and creation of a draft Publisher from source management when no matching organisation exists. Show linked sources and an article drilldown from either direction. Unsaved organisations must be saved before feeds can be attached. Archive/deletion and publication of organisations do not silently change source activation. Avoid destructive source deletion; staff can disable feeds while retaining article provenance.

Use dedicated guarded admin RPCs because existing news_sources SELECT policy only exposes active rows. Validate source edits server-side, preserve non-editable ingestion fields, prevent duplicate feed URLs, and check publisher role and lifecycle on linking. Permissions align with the admin-only Organisation editor. Tests cover source CRUD/linking, unlinked/paused reads, publisher validation, stale saves, suggestions and cross-navigation, plus existing route/typography gates. Verify desktop/mobile rendering and database operations with rollback fixtures.
