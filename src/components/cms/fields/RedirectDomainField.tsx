import { useEffect } from 'react';
import { useAuth } from '@/hooks/useAuth';
import { useRedirectDomainChoices } from '@/hooks/useRedirectDomainChoices';
import { RedirectDomainSelect } from '@/components/admin/redirects/RedirectDomainSelect';
import type { FieldProps } from './FieldRenderer';
export function RedirectDomainField({
  value,
  onChange,
  allValues,
  originalValues,
  disabled,
  error,
}: FieldProps) {
  const { user } = useAuth();
  const original = originalValues ?? allValues;
  const existing =
    allValues?.id && original?.type === 'SHORT'
      ? {
          id: typeof original.domain_id === 'string' ? original.domain_id : null,
          hostname: typeof original.domain_hostname === 'string' ? original.domain_hostname : null,
        }
      : undefined;
  const selection = useRedirectDomainChoices(
    user?.id,
    existing,
    value === null || (typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value))
      ? value
      : undefined,
  );
  const next = selection.valid
    ? selection.domainId
    : selection.query.isPending
      ? 'pending'
      : 'unavailable';
  useEffect(() => {
    if (user && value !== next) onChange(next);
  }, [value, next, onChange, user]);
  return (
    <>
      <RedirectDomainSelect
        isDomainRoot={allValues?.is_domain_root === true}
        selection={selection}
        slug={String(allValues?.slug ?? '')}
        disabled={disabled}
      />
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
    </>
  );
}
