import { useEffect, useRef } from 'react';
import { useLocation, useNavigate } from 'react-router';
import { useAuth } from '@/hooks/useAuth';
import { supabase } from '@/integrations/supabase/client';
import { analyticsAllowed, onAnalyticsConsentChange } from '@/lib/analyticsConsent';
import {
  captureRedirectAttribution,
  clearRedirectAttribution,
  readRedirectAttribution,
} from '@/lib/redirects/attribution';

/** Only confirmed account creation can become a native lead, verified again on the server. */
export function RedirectAttribution() {
  const { user } = useAuth();
  const location = useLocation(),
    navigate = useNavigate();
  const completed = useRef(new Set<string>());
  const pending = useRef(new Map<string, AbortController>());
  useEffect(
    () => () => {
      for (const request of pending.current.values()) request.abort();
      pending.current.clear();
    },
    [],
  );
  useEffect(() => {
    const run = (allowed: boolean) => {
      if (!allowed) {
        clearRedirectAttribution();
        for (const request of pending.current.values()) request.abort();
        pending.current.clear();
        completed.current.clear();
        return;
      }
      const url = new URL(
        location.pathname + location.search + location.hash,
        window.location.origin,
      );
      if (captureRedirectAttribution(url, true)) {
        url.searchParams.delete('qg_click_id');
        void navigate(url.pathname + url.search + url.hash, {
          replace: true,
          state: location.state,
        });
        return;
      }
      const click = readRedirectAttribution(true);
      if (!click || !user || user.is_anonymous || !(user.email_confirmed_at || user.confirmed_at))
        return;
      const key = user.id + ':' + click.clickId;
      if (completed.current.has(key) || pending.current.has(key)) return;
      const abort = new AbortController();
      pending.current.set(key, abort);
      void supabase.functions
        .invoke('redirect-api/native/signup', {
          body: { clickId: click.clickId },
          signal: abort.signal,
        })
        .then(({ data, error }) => {
          const terminal =
            error?.context instanceof Response && [400, 404, 409].includes(error.context.status);
          if (!abort.signal.aborted && ((!error && !data?.error) || terminal))
            completed.current.add(key);
        })
        .catch(() => {})
        .finally(() => {
          if (pending.current.get(key) === abort) pending.current.delete(key);
        });
    };
    run(analyticsAllowed());
    const unsubscribe = onAnalyticsConsentChange(run);
    return unsubscribe;
  }, [user, location.pathname, location.search, location.hash, location.state, navigate]);
  return null;
}
