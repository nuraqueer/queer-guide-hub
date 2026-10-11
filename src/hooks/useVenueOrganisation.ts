import { useQuery } from '@tanstack/react-query';
import { untypedRpc } from '@/integrations/supabase/untyped';

/** Compatibility bridge for legacy location IDs; resolving never changes the location ID. */
export function useVenueOrganisation(venueId: string | null) {
  return useQuery({
    queryKey: ['venue-organisation', venueId],
    enabled: Boolean(venueId),
    queryFn: async () => {
      const { data, error } = await untypedRpc('cms_venue_organisation', { p_venue_id: venueId });
      if (error) throw error;
      if (typeof data !== 'string')
        throw new Error('Could not resolve the organisation for this location.');
      return data;
    },
  });
}
