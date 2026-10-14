import { useQuery } from '@tanstack/react-query';
import { readLinkedDomains } from '@/lib/redirects/linkedDomains';
export function useLinkedRedirectDomains(userId: string, enabled = true) {
  return useQuery({
    queryKey: ['redirect-member', userId, 'linked-domains'],
    enabled,
    queryFn: ({ signal }) => readLinkedDomains(signal),
    staleTime: 0,
    retry: false,
    refetchOnWindowFocus: 'always',
  });
}
