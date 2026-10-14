/**
 * PageLoadingState — Unified skeleton loading for list/grid pages.
 */

import { useTranslation } from 'react-i18next';
import { Skeleton } from '@/components/ui/skeleton';
import { Card, CardContent } from '@/components/ui/card';
import { LoadingRegion } from '@/components/ui/loading-region';

interface PageLoadingStateProps {
  count?: number;
  variant?: 'card' | 'list';
  label?: string;
  slowMessage?: string;
  onRetry?: () => void;
}

export const PageLoadingState = ({
  count = 6,
  variant = 'card',
  label,
  slowMessage,
  onRetry,
}: PageLoadingStateProps) => {
  const { t } = useTranslation();
  const accessibleLabel = label ?? t('common.loading', 'Loading');
  const loadingProps = { label: accessibleLabel, slowMessage, onRetry };

  if (variant === 'list') {
    return (
      <LoadingRegion {...loadingProps} className="relative flex min-w-0 flex-col gap-4">
        {Array.from({ length: count }).map((_, i) => (
          <Card key={i}>
            <CardContent className="flex items-center gap-4">
              <Skeleton className="w-20 h-15 rounded-element shrink-0" style={{ height: 60 }} />
              <div className="min-w-0 flex-1">
                <Skeleton className="h-6 w-3/5" />
                <Skeleton className="h-[18px] w-2/5 mt-2" />
                <div className="flex gap-2 mt-1 overflow-hidden">
                  <Skeleton className="h-5 w-12 rounded-badge" />
                  <Skeleton className="h-5 w-16 rounded-badge" />
                </div>
              </div>
              <Skeleton className="h-8 w-16 rounded-element" />
            </CardContent>
          </Card>
        ))}
      </LoadingRegion>
    );
  }

  return (
    <LoadingRegion
      {...loadingProps}
      className="grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-3"
    >
      {Array.from({ length: count }).map((_, i) => (
        <Card key={i}>
          <CardContent>
            <div className="flex items-center gap-4">
              <Skeleton className="w-10 h-10 rounded-full" />
              <div className="min-w-0 flex-1">
                <Skeleton className="h-6 w-[70%]" />
                <Skeleton className="h-[18px] w-2/5 mt-2" />
              </div>
            </div>
            <Skeleton className="h-4 w-full mt-4" />
            <Skeleton className="h-4 w-3/5 mt-2" />
            <div className="flex gap-2 mt-2">
              <Skeleton className="h-6 w-16 rounded-badge" />
              <Skeleton className="h-6 w-20 rounded-badge" />
            </div>
          </CardContent>
        </Card>
      ))}
    </LoadingRegion>
  );
};
