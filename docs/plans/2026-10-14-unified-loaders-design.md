# Unified loaders

Requested: remove the intermittent pink loading appearance and unify public and admin loading UI.

Use the incumbent paper/ink identity. Remove the route-dependent, fixed-duration full-screen journey overlay; route changes retain the quiet content arrival. Actual pending requests own their loading feedback.

The existing track loop defaults to neutral ink. Public and admin loading regions share a 400 ms quiet window, polite labelled status, and an eight-second slow state. Skeletons keep content-specific shapes and use the existing muted token. Admin skeleton APIs remain as compatibility aliases to shared UI templates; table rows retain valid markup. The admin editor shell and legacy optimized loader also use the shared region.

No backend service or data model changes are required. Here backend means the admin interface.
