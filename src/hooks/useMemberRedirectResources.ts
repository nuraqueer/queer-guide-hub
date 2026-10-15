import { useQuery } from '@tanstack/react-query';
import { memberResources } from '@/lib/redirects/memberApi';
export function useMemberRedirectResources(userId: string) {
  return useQuery({
    queryKey: ['redirect-member', userId, 'resources'],
    queryFn: ({ signal }) => memberResources(signal),
    staleTime: 0,
    refetchOnWindowFocus: 'always',
  });
}
