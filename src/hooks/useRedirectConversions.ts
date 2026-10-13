import { useQuery, useInfiniteQuery } from '@tanstack/react-query';
import { untypedFrom, untypedRpc } from '@/integrations/supabase/untyped';
import { readInventoryPages } from '@/lib/redirects/inventory';
import type { JourneyEvent, RedirectConversion } from '@/lib/redirects/conversions';
export function useRedirectConversions(linkId?: string, days = '30') {
  return useQuery({
    queryKey: ['redirect-conversion-report', linkId, days],
    enabled: !!linkId,
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
interface JourneyPage {
  data: JourneyEvent[];
  nextCursor: { at: string; id: string } | null;
}
export function useRedirectCustomerJourney(customer: string | null) {
  return useInfiniteQuery({
    queryKey: ['redirect-customer-journey', customer],
    enabled: !!customer,
    initialPageParam: null as JourneyPage['nextCursor'],
    queryFn: async ({ pageParam }) => {
      const { data, error } = await untypedRpc<JourneyPage>('redirect_customer_journey', {
        p_customer_key: customer,
        p_after_at: pageParam?.at ?? null,
        p_after_id: pageParam?.id ?? null,
        p_limit: 50,
      });
      if (error || !data) throw new Error(error?.message ?? 'Could not load customer journey');
      return data;
    },
    getNextPageParam: (page) => page.nextCursor ?? undefined,
  });
}
