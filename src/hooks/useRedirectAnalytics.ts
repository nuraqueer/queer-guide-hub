import { useQuery, useInfiniteQuery } from '@tanstack/react-query';
import { untypedRpc } from '@/integrations/supabase/untyped';
import type { AnalyticsFilters, AnalyticsPage, AnalyticsReport } from '@/lib/redirects/analytics';
export async function readAnalyticsPage(
  filters: AnalyticsFilters,
  snapshot: string | null,
  cursor: AnalyticsPage['nextCursor'] = null,
  limit = 100,
) {
  const { data, error } = await untypedRpc<AnalyticsPage>('redirect_analytics_page', {
    p_filters: filters,
    p_snapshot: snapshot,
    p_before_at: cursor?.at ?? null,
    p_before_id: cursor?.id ?? null,
    p_limit: limit,
  });
  if (error || !data) throw new Error(error?.message ?? 'Could not load event activity');
  return data;
}
export function useRedirectAnalytics(filters: AnalyticsFilters, live: boolean) {
  const report = useQuery({
    queryKey: ['redirect-analytics-report', filters],
    queryFn: async () => {
      const { data, error } = await untypedRpc<AnalyticsReport>('redirect_analytics_report', {
        p_filters: filters,
      });
      if (error || !data) throw new Error(error?.message ?? 'Could not load analytics');
      return data;
    },
    refetchInterval: live ? 5000 : false,
    refetchIntervalInBackground: false,
  });
  const snapshot = report.data?.snapshot ?? null;
  const events = useInfiniteQuery({
    queryKey: ['redirect-analytics-events', filters, snapshot],
    enabled: !!snapshot,
    initialPageParam: null as AnalyticsPage['nextCursor'],
    queryFn: ({ pageParam }) => readAnalyticsPage(filters, snapshot, pageParam, 50),
    getNextPageParam: (page) => page.nextCursor ?? undefined,
  });
  return { report, events };
}
