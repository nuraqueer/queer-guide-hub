import { useTranslation } from 'react-i18next';
import { TrackLoader } from '@/components/transit/TrackLoader';
import { PageLoadingState } from '@/components/layout/PageLoadingState';
import { LoadingRegion } from './loading-region';

interface LoadingProps {
  size?: 'sm' | 'md' | 'lg';
  text?: string;
  /** Accessible name announced to screen readers when no visible text is shown. */
  label?: string;
  className?: string;
}

const loaderSize = { sm: 16, md: 24, lg: 32 } as const;

export function Loading({ size = 'md', text, label, className }: LoadingProps) {
  return (
    <LoadingRegion
      label={text ?? label}
      className={`flex flex-col items-center justify-center gap-4 ${className ?? ''}`}
    >
      <TrackLoader size={loaderSize[size]} delayMs={0} />
      {text && <p className="text-sm text-muted-foreground m-0">{text}</p>}
    </LoadingRegion>
  );
}

interface LoadingSpinnerProps {
  size?: 'sm' | 'md' | 'lg';
  /** Accessible name; set to null when a parent already exposes a status region. */
  label?: string | null;
  className?: string;
}

export function LoadingSpinner({ size = 'md', label, className }: LoadingSpinnerProps) {
  const { t } = useTranslation();
  return (
    <TrackLoader
      size={loaderSize[size]}
      className={className}
      label={label === null ? undefined : (label ?? t('common.loading', 'Loading'))}
    />
  );
}

interface PageLoadingProps {
  text?: string;
}

export function PageLoading({ text }: PageLoadingProps) {
  const { t } = useTranslation();
  const label = text ?? t('common.loading');

  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-reading">
        <span className="sr-only">{label}</span>
        <PageLoadingState count={3} variant="list" label={label} />
      </div>
    </div>
  );
}

interface InlineLoadingProps {
  text?: string;
  size?: 'sm' | 'md';
}

export function InlineLoading({ text, size = 'md' }: InlineLoadingProps) {
  const { t } = useTranslation();
  const label = text ?? t('common.loading');

  return (
    <LoadingRegion label={label} className="flex items-center justify-center gap-4 py-8">
      <TrackLoader size={loaderSize[size]} delayMs={0} />
      <span className={`text-muted-foreground ${size === 'sm' ? 'text-sm' : 'text-base'}`}>
        {label}
      </span>
    </LoadingRegion>
  );
}
