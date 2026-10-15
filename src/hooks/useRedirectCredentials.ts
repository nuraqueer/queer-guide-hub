import { useEffect, useRef } from 'react';
import { useAuth } from '@/hooks/useAuth';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { readInventoryPages } from '@/lib/redirects/inventory';
export interface RedirectCredential {
  id: string;
  name: string;
  prefix: string;
  scopes: string[];
  redirect_ids: string[] | null;
  member_id?: string | null;
  created_at: string;
  expires_at: string;
  revoked_at: string | null;
  last_used_at: string | null;
}
export function useRedirectCredentials() {
  const { user } = useAuth();
  const client = useQueryClient();
  const alive = useRef(true);
  const controller = useRef(new AbortController());
  useEffect(() => {
    alive.current = true;
    if (controller.current.signal.aborted) controller.current = new AbortController();
    return () => {
      alive.current = false;
      controller.current.abort();
    };
  }, []);
  const query = useQuery({
    queryKey: ['redirect-api-credentials', user?.id],
    enabled: !!user,
    gcTime: 0,
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
    retry: false,
    gcTime: 0,
    mutationFn: async (body: {
      name: string;
      expiresAt: string;
      redirectIds?: string[];
      memberId?: string;
      scopes?: string[];
    }) => {
      const { data, error } = await supabase.functions.invoke('redirect-api/tokens', {
        body,
        signal: controller.current.signal,
      });
      if (error || data?.error) throw new Error(data?.error ?? error?.message);
      return data as RedirectCredential & { secret: string };
    },
    onError: () =>
      alive.current
        ? client.invalidateQueries({ queryKey: ['redirect-api-credentials', user?.id] })
        : undefined,
    onSuccess: () =>
      alive.current
        ? client.invalidateQueries({ queryKey: ['redirect-api-credentials', user?.id] })
        : undefined,
  });
  const revoke = useMutation({
    gcTime: 0,
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.functions.invoke('redirect-api/tokens/' + id, {
        method: 'DELETE',
        signal: controller.current.signal,
      });
      if (error || data?.error) throw new Error(data?.error ?? error?.message);
    },
    onError: () =>
      alive.current
        ? client.invalidateQueries({ queryKey: ['redirect-api-credentials', user?.id] })
        : undefined,
    onSuccess: () =>
      alive.current
        ? client.invalidateQueries({ queryKey: ['redirect-api-credentials', user?.id] })
        : undefined,
  });
  return { ...query, create, revoke };
}
