import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { readRedirectDomainChoices } from '@/lib/redirects/domainChoices';
export function useRedirectDomainChoices(
  userId: string | undefined,
  existing?: { id: string | null; hostname: string | null },
  initialValue?: string | null,
) {
  const query = useQuery({
    queryKey: ['redirect-domain-choices', userId],
    enabled: !!userId,
    queryFn: ({ signal }) => readRedirectDomainChoices(signal),
    staleTime: 0,
    retry: false,
    refetchOnWindowFocus: 'always',
  });
  const [override, setOverride] = useState<{ userId: string | undefined; value: string } | null>(
    initialValue === undefined || (existing && initialValue === existing.id)
      ? null
      : { userId, value: initialValue ?? '' },
  );
  const selected =
    override && override.userId === userId
      ? override.value
      : existing
        ? (existing.id ?? '')
        : query.data?.primaryUnavailable
          ? 'unavailable'
          : (query.data?.primaryDomainId ?? '');
  const choice = query.data?.data.find((domain) => domain.id === selected);
  const preserving = !!existing && selected === (existing.id ?? '');
  const valid =
    !!userId &&
    (preserving ||
      (!!query.data && !query.isError && selected !== 'unavailable' && (!selected || !!choice)));
  const hostname = choice?.hostname ?? (preserving ? existing?.hostname : null) ?? null;
  return {
    query,
    selected,
    hostname,
    domainId: selected || null,
    valid,
    preserving,
    existing,
    resetSelection: () => setOverride(null),
    setSelected: (value: string) => setOverride({ userId, value }),
  };
}
export type RedirectDomainSelection = ReturnType<typeof useRedirectDomainChoices>;
