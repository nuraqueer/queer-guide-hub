import { Skeleton } from '@/components/ui/skeleton';
import { LoadingRegion } from './loading-region';
import { useLoaderDelay } from '@/components/transit/useLoaderDelay';
import { useTranslation } from 'react-i18next';
import { cn } from '@/lib/utils';

/**
 * Content-shaped loading affordances shared by the public site and admin.
 *
 * The rule, which admin had never applied consistently: a **skeleton** on first
 * load (nothing on screen yet, so show the shape that is coming), a **spinner**
 * only when refetching over content that is already rendered, and never bare
 * "Loading..." text — it collapses the layout and reads as a stuck page.
 */

/** Rows-and-columns placeholder for a table that has not loaded yet. */
export function LoadingTableSkeleton({
  rows = 5,
  columns = 5,
  className,
}: {
  rows?: number;
  columns?: number;
  className?: string;
}) {
  return (
    <LoadingRegion className={cn('min-w-0 p-4', className)}>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="flex gap-4 border-b border-border py-4">
          {Array.from({ length: columns }).map((_, j) => (
            <Skeleton
              key={j}
              className="h-5 min-w-0 flex-1"
              style={{ maxWidth: j === 0 ? 180 : 100 }}
            />
          ))}
        </div>
      ))}
    </LoadingRegion>
  );
}

/**
 * Skeleton rows for a <tbody>.
 *
 * A div-based skeleton is invalid HTML inside <table> and gets hoisted out by
 * the parser, so the seven pipeline-builder tables that rendered
 * `<tr><td colSpan={n}>Loading…</td></tr>` need this shape specifically.
 */
export function LoadingTableRowSkeleton({ columns, rows = 3 }: { columns: number; rows?: number }) {
  const { t } = useTranslation();
  const { visible, slow } = useLoaderDelay(true);
  if (slow) {
    return (
      <tr>
        <td colSpan={columns} className="p-4">
          <span role="status" aria-live="polite">
            {t('common.loadingSlow', 'This is taking longer than expected.')}
          </span>
        </td>
      </tr>
    );
  }
  return (
    <>
      {Array.from({ length: rows }).map((_, r) => (
        <tr key={r} className={visible ? undefined : 'invisible'}>
          {Array.from({ length: columns }).map((_, c) => (
            <td key={c} className="p-4">
              {r === 0 && c === 0 && (
                <span className="sr-only" role="status" aria-live="polite">
                  {t('common.loading', 'Loading')}
                </span>
              )}
              <Skeleton className="h-4" style={{ width: c === 0 ? '70%' : '45%' }} />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

/**
 * Bare stack of text-line placeholders, no border or heading.
 *
 * For first-load INSIDE a container that already draws its own chrome — a
 * <Card> body, a panel section. LoadingCardSkeleton would nest a border in a
 * border there; this is the shape those ~25 `<p>Loading…</p>` sites needed.
 */
export function LoadingTextSkeleton({
  lines = 3,
  className,
}: {
  lines?: number;
  className?: string;
}) {
  return (
    <LoadingRegion className={cn('flex flex-col gap-2', className)}>
      {Array.from({ length: lines }).map((_, i) => (
        <Skeleton key={i} className="h-4" style={{ width: i === lines - 1 ? '60%' : '100%' }} />
      ))}
    </LoadingRegion>
  );
}

/** Heading-plus-body placeholder for a card or panel. */
export function LoadingCardSkeleton({
  lines = 3,
  className,
}: {
  lines?: number;
  className?: string;
}) {
  return (
    <LoadingRegion className={cn('rounded-container p-6', className)}>
      <Skeleton className="mb-4 h-6 w-48" />
      <div className="flex flex-col gap-2">
        {Array.from({ length: lines }).map((_, i) => (
          <Skeleton key={i} className="h-4" style={{ width: i === lines - 1 ? '60%' : '100%' }} />
        ))}
      </div>
    </LoadingRegion>
  );
}
