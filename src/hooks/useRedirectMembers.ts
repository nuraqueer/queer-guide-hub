import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
export interface RedirectMember {
  id: string;
  user_id: string | null;
  kind: 'user' | 'machine';
  label: string;
  role: 'member' | 'viewer';
  active: boolean;
}
export function useRedirectMembers() {
  return useQuery<RedirectMember[]>({
    queryKey: ['redirect-workspace-members'],
    queryFn: async ({ signal }) => {
      const result: RedirectMember[] = [];
      for (let offset = 0; ; offset += 100) {
        const { data, error } = await supabase.functions.invoke(
          'redirect-api/members?offset=' + offset,
          { method: 'GET', signal },
        );
        if (error || data?.error)
          throw new Error(data?.error ?? error?.message ?? 'Could not load members');
        result.push(...data.data);
        if (result.length >= data.count) return result;
        if (!data.data.length) throw new Error('Member page was incomplete. Retry.');
      }
    },
  });
}
