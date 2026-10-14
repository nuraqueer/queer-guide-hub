import { TrackLoader } from '@/components/transit/TrackLoader';

// Compatibility names: all skeleton behavior lives in the shared UI primitives.
export {
  LoadingTableSkeleton as AdminTableSkeleton,
  LoadingTableRowSkeleton as AdminTableRowSkeleton,
  LoadingTextSkeleton as AdminTextSkeleton,
  LoadingCardSkeleton as AdminCardSkeleton,
} from '@/components/ui/loading-skeleton';

/** Neutral, shared indicator for refetches over existing content. */
export function AdminInlineSpinner({
  className,
  label = 'Refreshing',
}: {
  className?: string;
  label?: string;
}) {
  return <TrackLoader size={14} label={label} className={className} />;
}
