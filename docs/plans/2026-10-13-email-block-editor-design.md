# Email block editor

Approved by the user on 2026-10-13 after the deployed email designer review.

Use React Email Editor to add WYSIWYG blocks for headings, text, images, buttons, dividers and columns, inline formatting, contextual properties, undo/redo and block ordering. Inherit the existing operational admin identity.

Keep legacy template HTML intact until explicit conversion. Show the converted draft before saving. Export email HTML and plain text into the existing template delivery contract. Protect variable tokens and validate required placeholders. Provide desktop/mobile draft previews, visible unsaved state, discard protection and reachable save/test actions. Tests send the saved version and clearly explain when a draft must first be saved.

Use a compact template registry and a larger composition workspace. On narrow screens, allow template selection and wrap controls; do not clip actions. Preview sample values must not be persisted as template content. Keep existing sender/branding ownership in Design & branding.

Verify conversion, token handling, save failures, unsaved-switch protection, preview, block insert/reorder and responsive operation. No production templates are changed during implementation or verification.
