# Shared loading UI

Public and admin interfaces use the same neutral ink track loop and muted skeletons on the existing paper surface. Route changes never introduce a coloured full-screen overlay or an artificial wait.

- `Loading` and `InlineLoading`: a neutral track loop with an optional label.
- `LoadingSpinner`: compact indicator for existing content or buttons; pass `label={null}` when a parent announces the status.
- `PageLoadingState` / `PageLoading`: content-shaped page placeholders.
- `LoadingRegion`: shared status region for custom placeholder layouts.
- `LoadingTableSkeleton`, `LoadingTableRowSkeleton`, `LoadingTextSkeleton`, `LoadingCardSkeleton`: shared content templates. The admin names re-export these for compatibility.

Regions reserve their layout immediately, reveal after 400 ms, and replace animated placeholders with explanatory text after eight seconds. Pass `onRetry` only when the caller has an actual retry action. Table-row placeholders keep valid table markup and the same timing. Small standalone track loops stop moving after eight seconds. Reduced motion retains a static, neutral indicator.

Give a region a useful `label`, and avoid nesting status announcements. Keep the shapes appropriate to the incoming content; visual consistency does not require tables and cards to have the same layout.
