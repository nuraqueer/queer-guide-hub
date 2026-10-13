import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { readInventoryPages } from '@/lib/redirects/inventory';
export interface RedirectCredential {
  id: string;
  name: string;
  prefix: string;
  scopes: string[];
  redirect_ids: string[] | null;
  created_at: string;
  expires_at: string;
  revoked_at: string | null;
  last_used_at: string | null;
}
export function useRedirectCredentials() {
  const client = useQueryClient();
  const query = useQuery({
    queryKey: ['redirect-api-credentials'],
    queryFn: async ({ signal }) =>
      (await readInventoryPages(async (offset) => {
        const { data, error } = await supabase.functions.invoke(
          'redirect-api/tokens?offset=' + offset,
          { method: 'GET', signal },
        );
        if (error || data?.error) throw new Error(data?.error ?? error?.message);
        return { data: data.data, count: data.count, error: null };
      })) as unknown as RedirectCredential[],
  });
  const create = useMutation({
    mutationFn: async (body: { name: string; expiresAt: string; redirectIds?: string[] }) => {
      const { data, error } = await supabase.functions.invoke('redirect-api/tokens', { body });
      if (error || data?.error) throw new Error(data?.error ?? error?.message);
      return data as RedirectCredential & { secret: string };
    },
    onSuccess: () => client.invalidateQueries({ queryKey: ['redirect-api-credentials'] }),
  });
  const revoke = useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.functions.invoke('redirect-api/tokens/' + id, {
        method: 'DELETE',
      });
      if (error || data?.error) throw new Error(data?.error ?? error?.message);
    },
    onSuccess: () => client.invalidateQueries({ queryKey: ['redirect-api-credentials'] }),
  });
  return { ...query, create, revoke };
}
