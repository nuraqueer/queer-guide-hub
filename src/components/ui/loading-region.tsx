import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { useLoaderDelay } from '@/components/transit/useLoaderDelay';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

export interface LoadingRegionProps {
  children: ReactNode;
  label?: string;
  className?: string;
  slowMessage?: string;
  onRetry?: () => void;
}

/** Shared by public and admin loaders. Reserve the layout for fast requests,
 * reveal after 400ms, and replace indefinite animation with useful copy at 8s. */
export function LoadingRegion({
  children,
  label,
  className,
  slowMessage,
  onRetry,
}: LoadingRegionProps) {
  const { t } = useTranslation();
  const { visible, slow } = useLoaderDelay(true);
  const accessibleLabel = label ?? t('common.loading', 'Loading');
  return (
    <div
      role="status"
      aria-live="polite"
      aria-label={accessibleLabel}
      className={cn('content-crossfade-enter', !visible && 'invisible', className)}
    >
      {slow ? (
        <div className="flex flex-col items-start gap-4 text-sm text-muted-foreground">
          <p className="m-0">
            {slowMessage ?? t('common.loadingSlow', 'This is taking longer than expected.')}
          </p>
          {onRetry && (
            <Button variant="outline" onClick={onRetry}>
              {t('common.retry', 'Retry')}
            </Button>
          )}
        </div>
      ) : (
        children
      )}
    </div>
  );
}
