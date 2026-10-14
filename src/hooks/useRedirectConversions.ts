import { useAuth } from './useAuth';
import { readCustomerJourney, type CustomerJourneyCursor } from '@/lib/redirects/customers';
import { useQuery, useInfiniteQuery } from '@tanstack/react-query';
import { untypedFrom } from '@/integrations/supabase/untyped';
import { readInventoryPages } from '@/lib/redirects/inventory';
import type { RedirectConversion } from '@/lib/redirects/conversions';
export function useRedirectConversions(linkId?: string, days = '30') {
  const { user } = useAuth();
  return useQuery({
    queryKey: ['redirect-conversion-report', user?.id, linkId, days],
    enabled: !!linkId && !!user?.id,
    queryFn: async ({ signal }) => {
      const since =
        days === 'all' ? null : new Date(Date.now() - Number(days) * 86400000).toISOString();
      return (await readInventoryPages(async (offset) => {
        let query = untypedFrom('redirect_conversion_report')
          .select('id,click_id,kind,event_name,occurred_at,customer_key,amount,currency', {
            count: 'exact',
          })
          .eq('redirect_id', linkId!)
          .order('occurred_at', { ascending: false })
          .order('id', { ascending: false })
          .range(offset, offset + 999);
        if (since) query = query.gte('click_ts', since);
        const { data, count, error } = await query.abortSignal(signal);
        return { data: data as Record<string, unknown>[] | null, count, error };
      })) as unknown as RedirectConversion[];
    },
  });
}
export function useRedirectCustomerJourney(customer: string | null) {
  const { user } = useAuth();
  return useInfiniteQuery({
    queryKey: ['redirect-customer-journey', user?.id, customer],
    enabled: !!customer && !!user?.id,
    initialPageParam: null as CustomerJourneyCursor | null,
    queryFn: ({ pageParam, signal }) => readCustomerJourney(customer!, pageParam, signal),
    getNextPageParam: (page) => page.nextCursor ?? undefined,
    gcTime: 0,
    staleTime: 0,
    retry: false,
  });
}
